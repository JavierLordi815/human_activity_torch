--[[
    Data sampling/fetching functions.
]]


-------------------------------------------------------------------------------
-- Data loading functions
-------------------------------------------------------------------------------

local function get_db_loader(name)
    local dbc = require 'dbcollection'

    local dbloader
    local str = string.lower(name)
    if str == 'ucf_sports' then
        dbloader = dbc.load{name='ucf_sports', task='recognition', data_dir=opt.data_dir}
    elseif str == 'ucf_101' then
        dbloader = dbc.load{name='ucf_101', task='recognition', data_dir=opt.data_dir}
    else
        error(('Invalid dataset name: %s. Available datasets: ucf_sports | ucf_101.'):format(name))
    end
    return dbloader
end

------------------------------------------------------------------------------------------------------------

local function loader_ucf_sports(set_name)
    local utils = require 'dbcollection.utils'
    local ascii2str = utils.string_ascii.convert_ascii_to_str
    local unpad_list = utils.pad.unpad_list

    local dbloader = get_db_loader('ucf_sports')

    -- number of samples per train/test sets
    local set_size = dbloader:size(set_name)[1]

    -- number of categories
    local num_activities = dbloader:size(set_name, 'activities')[1]

    local activities = ascii2str(dbloader:get(set_name, 'activities'))

    -- number of videos
    local num_videos = dbloader:size(set_name, 'videos')[1]

    -- data loader function
    local data_loader = function(idx)

        -- fetch all object ids belonging to the video
        local obj_ids = unpad_list(dbloader:get(set_name, 'list_object_ids_per_video', idx) + 1, 0)  -- set to 1-index

        local tmp_data = dbloader:object(set_name, obj_ids[1])
        local label = tmp_data[1][4]

        -- get data from the selected video
        local imgs = {}
        for iobj=1, #obj_ids do
            local data = dbloader:object(set_name, obj_ids[iobj], true)

            local filename = ascii2str(data[1])
            local img_filename = paths.concat(dbloader.data_dir, filename)
            local img = image.load(img_filename, 3, 'float')

            local bbox = data[2]:squeeze()
            local center = torch.FloatTensor{(bbox[1]+bbox[3])/2, (bbox[2]+bbox[4])/2}
            local scale = (bbox[4]-bbox[2]) / 200 * 1.25

            if scale < 0 then
                scale = 1.25
            end

            table.insert(imgs, {img = img,
                                center = center,
                                scale = scale,
                                filename = img_filename,
                                bbox = bbox})
        end

        return imgs, label
    end

    -- return a list of all video ids of an activity
    local get_video_ids_activity = function(activity_id)
        return unpad_list(dbloader:get(set_name, 'list_videos_per_activity', activity_id))
    end

    return {
        loader = data_loader,
        get_video_ids = get_video_ids_activity,
        activities = activities,
        size = set_size,
        num_activities = num_activities,
        num_videos = num_videos,
        set = set_name,
    }
end

------------------------------------------------------------------------------------------------------------

local function loader_ucf_101(set_name)
    local string_ascii = require 'dbcollection.utils.string_ascii'
    local ascii2str = string_ascii.convert_ascii_to_str

    local dbloader = get_db_loader('ucf_101')

    -- number of samples per train/test sets
    local set_size = dbloader:size(set_name)[1]

    -- TODO

    return {
        loader = data_loader,
        size = set_size,
        num_keypoints = nJoints
    }
end

------------------------------------------------------------------------------------------------------------

local function fetch_loader_dataset(name, mode)
    local str = string.lower(name)
    if str == 'ucf_sports' then
        return loader_ucf_sports(mode)
    elseif str == 'ucf_101' then
        return loader_ucf_101(mode)
    else
        error(('Invalid dataset name: %s. Available datasets: ucf_sports | ucf_101.'):format(name))
    end
end
------------------------------------------------------------------------------------------------------------

function select_dataset_loader(name)
    assert(name)

    return {
        train = fetch_loader_dataset(name, 'train01'),
        test = fetch_loader_dataset(name, 'test01')
    }
end