describe("AnnotationSync menu location setting", function()
    local UIManager, AnnotationSyncPlugin, test_utils
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_menu_location_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        UIManager = require("ui/uimanager")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
    end)

    teardown(function()
        if readerui then readerui:onClose() end
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)

    before_each(function()
        readerui, sync_instance = test_utils.init_integration_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
    end)

    it("defaults menu_location to 'tools' on a fresh install", function()
        assert.is_equal("tools", sync_instance.settings.menu_location)
    end)

    it("sets sorting_hint to 'tools' by default", function()
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        assert.is_equal("tools", menu_items.annotation_sync_plugin.sorting_hint)
    end)

    it("sets sorting_hint to 'more_tools' when menu_location is 'more_tools'", function()
        sync_instance.settings.menu_location = "more_tools"
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        assert.is_equal("more_tools", menu_items.annotation_sync_plugin.sorting_hint)
    end)

    it("omits sorting_hint entirely when menu_location is 'none'", function()
        sync_instance.settings.menu_location = "none"
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        assert.is_nil(menu_items.annotation_sync_plugin.sorting_hint)
    end)

    it("backfills menu_location to 'tools' for settings saved before this feature existed", function()
        -- Simulate a pre-existing settings file with no menu_location key
        sync_instance.settings.menu_location = nil
        sync_instance:saveSettings()

        local readerui2, sync_instance2 = test_utils.init_integration_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
        assert.is_equal("tools", sync_instance2.settings.menu_location)
        readerui2:onClose()
    end)

    local function find_settings_submenu(sync_instance)
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        return menu_items.annotation_sync_plugin.sub_item_table[1]
    end

    local function find_menu_location_submenu(sync_instance)
        local settings_menu = find_settings_submenu(sync_instance)
        for _, item in ipairs(settings_menu.sub_item_table) do
            if item.text == "Menu location" then
                return item
            end
        end
        return nil
    end

    it("exposes a 'Menu location' submenu with Tools / More tools / None options", function()
        local submenu = find_menu_location_submenu(sync_instance)
        assert.is_not_nil(submenu)
        assert.is_not_nil(submenu.sub_item_table)
        assert.is_equal(3, #submenu.sub_item_table)
        assert.is_equal("Tools", submenu.sub_item_table[1].text)
        assert.is_equal("More tools", submenu.sub_item_table[2].text)
        assert.is_equal("None (shown as new item)", submenu.sub_item_table[3].text)
    end)

    it("checks the option matching the current menu_location", function()
        sync_instance.settings.menu_location = "more_tools"
        local submenu = find_menu_location_submenu(sync_instance)
        assert.is_false(submenu.sub_item_table[1].checked_func())
        assert.is_true(submenu.sub_item_table[2].checked_func())
        assert.is_false(submenu.sub_item_table[3].checked_func())
    end)

    it("selecting 'More tools' updates and persists the setting", function()
        local submenu = find_menu_location_submenu(sync_instance)
        submenu.sub_item_table[2].callback()
        assert.is_equal("more_tools", sync_instance.settings.menu_location)

        local readerui2, sync_instance2 = test_utils.init_integration_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
        assert.is_equal("more_tools", sync_instance2.settings.menu_location)
        readerui2:onClose()
    end)

    it("selecting 'None' updates the setting and removes sorting_hint", function()
        local submenu = find_menu_location_submenu(sync_instance)
        submenu.sub_item_table[3].callback()
        assert.is_equal("none", sync_instance.settings.menu_location)

        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        assert.is_nil(menu_items.annotation_sync_plugin.sorting_hint)
    end)
end)
