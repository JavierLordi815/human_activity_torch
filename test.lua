--[[
    Script for testing a human activity estimator.

    Available/valid datasets: UCF Sports Action.
--]]


require 'paths'
require 'torch'
require 'string'
require 'optim'

local tnt = require 'torchnet'
local Logger = optim.Logger


--------------------------------------------------------------------------------
-- Load configs (data, model, criterion, optimState)
--------------------------------------------------------------------------------

print('==> (1/3) Load configurations: ')
paths.dofile('configs.lua')

-- load model from disk
print('==> (2/3) Load network from disk: ')
load_model('test')

-- set local vars
local lopt = opt
local nSamples = opt.test_num_videos

-- convert modules to a specified tensor type
local function cast(x) return x:type(opt.dataType) end


--------------------------------------------------------------------------------
-- Setup data generator
--------------------------------------------------------------------------------

local function getIterator(mode)
    return tnt.ParallelDatasetIterator{
        nthread = opt.nThreads,
        ordered = true,
        init    = function(threadid)
                    require 'torch'
                    require 'torchnet'
                    opt = lopt
                    paths.dofile('data.lua')
                    paths.dofile('sample_batch.lua')
                    torch.manualSeed(threadid+opt.manualSeed)
                  end,
        closure = function()

            -- setup data loader
            local data_loader = select_dataset_loader(opt.dataset, mode)
            local loader = data_loader[mode]

            -- setup dataset iterator
            return tnt.ListDataset{
                list = torch.range(1, nSamples):long(),
                load = function(idx)
                    local input_hms, input_feats, label = getSampleTest(loader, idx)
                    return {
                        input_hms = input_hms,
                        input_feats = input_feats,
                        target = label
                    }
                end
            }:batch(1, 'include-last')
        end,
    }
end


--------------------------------------------------------------------------------
-- Setup torchnet engine/meters/loggers
--------------------------------------------------------------------------------

local timers = {
   featTimer = torch.Timer(),
   clsTimer = torch.Timer(),
   totalTimer = torch.Timer(),
}

local meters = {
    confusion_matrix = tnt.ConfusionMeter{k = opt.num_activities},
    clerr = tnt.ClassErrorMeter{topk = {1,5},accuracy=true},
    ap = tnt.APMeter(),
}

function meters:reset()
    self.confusion_matrix:reset()
    self.clerr:reset()
    self.ap:reset()
end

local loggers = {
    test = Logger(paths.concat(opt.save,'Evaluation_full.log'), opt.continue),
    confusion_matrix = Logger(paths.concat(opt.save,'Evaluation_confusion.log'), opt.continue)
}

loggers.test:setNames{'Top-1 accuracy (%)', 'Top-5 accuracy (%)', 'Average Precision'}
loggers.confusion_matrix:setNames{'Test confusion matrix'}
loggers.test.showPlot = false
loggers.confusion_matrix.showPlot = false

-- set up training engine:
local engine = tnt.OptimEngine()

engine.hooks.onStart = function(state)
    print('\n*********************************************************')
    print(('Start testing the network on the %s dataset: '):format(opt.dataset))
    print('*********************************************************')
end


-- copy sample to GPU buffer:
local inputs, targets = cast(torch.Tensor()), cast(torch.Tensor())
local num_imgs_seq
engine.hooks.onSample = function(state)
    cutorch.synchronize(); collectgarbage();

    timers.featTimer:reset()

    if state.sample.input_feats then
        if type(state.sample.input_feats[1]) == 'userdata' then
            num_imgs_seq = state.sample.input_feats[1]:size(2)
        else
            num_imgs_seq = state.sample.input_hms[1]:size(2)
        end
    elseif state.sample.input_hms then
        num_imgs_seq = state.sample.input_hms[1]:size(2)
    else
        error('Error! No features for any nertwork is available!')
    end


    ------
    local function process_inputs(model, input)
        local inputs_features = {}
        if model then
            for i=1, num_imgs_seq do
                local img = input[1][i]
                local img_cuda = img:view(1, unpack(img:size():totable())):cuda()  -- extra dimension for cudnn batchnorm
                local features = model:forward(img_cuda)
                table.insert(inputs_features, features)
            end
            -- convert table into a single tensor
            inputs_features = nn.Unsqueeze(1):cuda():forward(nn.JoinTable(1):cuda():forward(inputs_features))
        end
        return inputs_features
    end
    ------

    local inputs_features, inputs_hms
    if model_features then inputs_features = process_inputs(model_features, state.sample.input_feats[1]) end
    if model_hms then
        inputs_hms = process_inputs(model_hms, state.sample.input_hms[1])
        inputs_hms[inputs_hms:lt(0)]=0
        inputs_hms = inputs_hms:view(1, inputs_hms:size(2), -1)
    end
    --local inputs_features = process_inputs(model_features, state.sample.input_feats[1])
    --local inputs_hms = process_inputs(model_hms, state.sample.input_hms[1])


    targets:resize(state.sample.target[1]:size() ):copy(state.sample.target[1])

    if model_features and model_hms then
        state.sample.input = {inputs_features, inputs_hms}
    elseif model_features then
        state.sample.input = inputs_features
    elseif model_hms then
        state.sample.input = inputs_hms
    else
        error('Invalid network type: ' .. opt.netType)
    end
    state.sample.target = targets:view(-1)

    timers.featTimer:stop()
    timers.clsTimer:reset()
end


local softmax = cast(nn.SoftMax())
engine.hooks.onForward= function(state)
    if opt.test_progressbar then
        xlua.progress(state.t, nSamples)
    else
        print(('test: %5d/%-5d ' .. 'seq_length=%d   ' ..
                'features forward time: %.3fs, classifier forward time: %.3fs, ' ..
                'total time: %0.3fs'):format(state.t, nSamples, num_imgs_seq,
                timers.featTimer:time().real,
                timers.clsTimer:time().real,
                timers.totalTimer:time().real))
    end

    local out = softmax:forward(state.network.output)
    if string.find(opt.netType, 'lstm') then
        local end_idx = state.sample.target:size(1)
        meters.clerr:add(out[{{end_idx}, {}}], state.sample.target[{{end_idx}}])
        meters.confusion_matrix:add(out[{{end_idx}, {}}], state.sample.target[{{end_idx}}])
        local tar = torch.ByteTensor(out:size(2)):fill(0)
        local id = state.sample.target[end_idx]
        tar[id] = 1
        meters.ap:add(out[end_idx],tar)
    elseif string.find(opt.netType, 'convnet') then
        out = out:mean(1):squeeze()  -- mean
        meters.clerr:add(out,state.sample.target[{{1}}])
        local tar = torch.ByteTensor(out:size(1)):fill(0)
        tar[state.sample.target[1]] = 1
        meters.ap:add(out,tar)
    else
        error('Invalid network type: ' .. opt.netType)
    end

    collectgarbage()

    timers.featTimer:resume()
    timers.totalTimer:reset()
end


engine.hooks.onEnd= function(state)
    loggers.test:add{meters.clerr:value{k = 1}, meters.clerr:value{k = 5},meters.ap:value():mean()}
    print("\nEvaluation complete!")
    print("Accuracy: Top 1%", meters.clerr:value{k = 1} .. '%')
    print("Accuracy: Top 5%", meters.clerr:value{k = 5} .. '%')
    print("mean AP:",meters.ap:value():mean())

    if opt.test_printConfusion then
        local ts = optim.ConfusionMatrix(opt.activities)
        ts.mat = meters.confusion_matrix:value()
        loggers.confusion_matrix:add{ts:__tostring__()} -- output the confusion matrix as a string
        print(ts)
    end
end


--------------------------------------------------------------------------------
-- Test the model
--------------------------------------------------------------------------------

engine:test{
    network  = model_classifier,
    iterator = getIterator('test')
}

print('\nTest script complete.')