describe("Issue #69 Reproduction: Slow sync with many annotations", function()
    local ReaderUI, UIManager
    local AnnotationSyncPlugin, test_utils, annotations_mod
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_perf_tmp"
    local old_getDataDir
    local sample_epub = "spec/front/unit/data/juliet.epub"

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        annotations_mod = require("annotations")

        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

        readerui, sync_instance = test_utils.init_integration_context(
            sample_epub, AnnotationSyncPlugin
        )
    end)

    teardown(function()
        if readerui then readerui:onClose() end
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = _G.old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end)

    before_each(function()
        UIManager:show(readerui)
        fastforward_ui_events()
    end)

    -- Builds `count` distinct, real, comparable xpointers spread across the
    -- real document, wrapping around the available page count if `count`
    -- exceeds it (still distinct as long as count <= page_count).
    local function collect_xpointers(count)
        local page_count = readerui.document:getPageCount()
        assert.is_true(
            count < page_count,
            string.format("Fixture document only has %d pages, need more than %d for distinct xpointers", page_count, count)
        )
        local xpointers = {}
        for i = 1, count do
            local page = ((i - 1) % (page_count - 1)) + 1
            table.insert(xpointers, readerui.document:getPageXPointer(page))
        end
        return xpointers
    end

    -- Builds local_map/last_uploaded_map annotation tables from a list of
    -- xpointers, alternating between "local" and "uploaded" so the two
    -- sorted key lists interleave (mirrors realistic non-overlapping
    -- highlights scattered through a book).
    local function build_maps(xpointers)
        local local_map, uploaded_map = {}, {}
        for i, xp in ipairs(xpointers) do
            local ann = {
                page = xp,
                pos0 = xp,
                pos1 = xp,
                text = "annotation " .. i,
                datetime_updated = "2026-01-01 00:00:00",
            }
            local key = annotations_mod.annotation_key(ann)
            if i % 2 == 0 then
                local_map[key] = ann
            else
                uploaded_map[key] = ann
            end
        end
        return local_map, uploaded_map
    end

    -- Wraps document:compareXPointers to count real invocations while still
    -- delegating to the real crengine implementation.
    local function with_counting_document(fn)
        local original = readerui.document.compareXPointers
        local call_count = 0
        readerui.document.compareXPointers = function(self, a, b)
            call_count = call_count + 1
            return original(self, a, b)
        end
        local ok, err = pcall(fn)
        readerui.document.compareXPointers = original
        if not ok then error(err) end
        return call_count
    end

    -- Runs get_deleted_annotations for `n` synthetic annotations against the
    -- real document, returning both the real compareXPointers call count and
    -- the wall-clock time for that single run.
    local function measure(n)
        local xpointers = collect_xpointers(n)
        local local_map, uploaded_map = build_maps(xpointers)
        local start = os.clock()
        local calls = with_counting_document(function()
            annotations_mod.get_deleted_annotations(local_map, uploaded_map, readerui.document)
        end)
        local elapsed = os.clock() - start
        return calls, elapsed
    end

    local function minmax(values)
        local lo, hi = math.huge, -math.huge
        for _, v in ipairs(values) do
            lo = math.min(lo, v)
            hi = math.max(hi, v)
        end
        return lo, hi
    end

    local function spread(values)
        local lo, hi = minmax(values)
        return hi / lo
    end

    it("marks deleted annotations correctly on a small known input", function()
        local xpointers = collect_xpointers(4)
        local local_map, uploaded_map = build_maps(xpointers)
        -- Drop one uploaded-only entry from local_map to simulate a real deletion.
        local deleted_key
        for k in pairs(uploaded_map) do
            if not local_map[k] then
                deleted_key = k
                break
            end
        end
        assert.truthy(deleted_key, "Expected at least one uploaded-only entry")

        annotations_mod.get_deleted_annotations(local_map, uploaded_map, readerui.document)

        assert.truthy(local_map[deleted_key], "Deleted annotation should be added to local_map")
        assert.is_true(local_map[deleted_key].deleted, "Missing annotation should be marked deleted")
    end)

    it("scales linearly (not quadratically) across multiple annotation counts, and projects the cost at ~1000 annotations", function()
        -- Sample several sizes across the range (not just one doubling), all
        -- comfortably below the real fixture's page count, so we can compare
        -- how well a linear model vs. a quadratic model fits the WHOLE curve.
        local sizes = { 15, 30, 60, 120, 220 }
        local results = {}
        for _, n in ipairs(sizes) do
            local calls, elapsed = measure(n)
            table.insert(results, { n = n, calls = calls, elapsed = elapsed })
            print(string.format(
                "[issue_69_perf_repro] n=%-4d calls=%-8d elapsed=%.4fs  calls/n=%8.2f  calls/n^2=%.4f  elapsed/n^2=%.6f",
                n, calls, elapsed, calls / n, calls / (n * n), elapsed / (n * n)
            ))
        end

        local calls_per_n, calls_per_n2 = {}, {}
        local elapsed_per_n, elapsed_per_n2 = {}, {}
        for _, r in ipairs(results) do
            table.insert(calls_per_n, r.calls / r.n)
            table.insert(calls_per_n2, r.calls / (r.n * r.n))
            table.insert(elapsed_per_n, r.elapsed / r.n)
            table.insert(elapsed_per_n2, r.elapsed / (r.n * r.n))
        end

        -- For a true O(n) algorithm, metric/n stays roughly constant across
        -- sizes (small spread) while metric/n^2 shrinks steadily as n grows
        -- (large spread). For O(n^2) it's the reverse. Comparing the two
        -- models' spread across ALL 5 sample points (rather than just
        -- interpolating between two points) is much stronger evidence of
        -- which model actually fits. This is a regression guard: after the
        -- issue #69 fix, the LINEAR model should fit far better than the
        -- quadratic one.
        local calls_linear_spread, calls_quad_spread = spread(calls_per_n), spread(calls_per_n2)
        print(string.format(
            "[issue_69_perf_repro] calls/n spread=%.2fx (linear-model fit) vs calls/n^2 spread=%.2fx (quadratic-model fit)",
            calls_linear_spread, calls_quad_spread
        ))
        assert.is_true(
            calls_linear_spread < calls_quad_spread,
            string.format(
                "Expected calls/n to be far more stable than calls/n^2 across sizes {%s} " ..
                "(linear model should fit much better than quadratic; if not, the O(n^2) bug from issue #69 may have regressed), " ..
                "got linear spread %.2fx vs quadratic spread %.2fx",
                table.concat(sizes, ","), calls_linear_spread, calls_quad_spread
            )
        )

        local elapsed_linear_spread, elapsed_quad_spread = spread(elapsed_per_n), spread(elapsed_per_n2)
        print(string.format(
            "[issue_69_perf_repro] elapsed/n spread=%.2fx (linear-model fit) vs elapsed/n^2 spread=%.2fx (quadratic-model fit)",
            elapsed_linear_spread, elapsed_quad_spread
        ))
        assert.is_true(
            elapsed_linear_spread < elapsed_quad_spread,
            string.format(
                "Expected elapsed/n to be far more stable than elapsed/n^2 across sizes {%s} " ..
                "(linear model should fit much better than quadratic; if not, the O(n^2) bug from issue #69 may have regressed), " ..
                "got linear spread %.2fx vs quadratic spread %.2fx",
                table.concat(sizes, ","), elapsed_linear_spread, elapsed_quad_spread
            )
        )

        -- Extrapolate to ~1000 annotations (the scale reported in the GitHub
        -- issue) using the LINEAR coefficients fitted from ALL 5 sampled
        -- points, reporting a min..max range (rather than a single-point
        -- estimate from interpolating just two sizes).
        local target_n = 1000
        local lo_calls_c, hi_calls_c = minmax(calls_per_n)
        local lo_elapsed_c, hi_elapsed_c = minmax(elapsed_per_n)
        print(string.format(
            "[issue_69_perf_repro] extrapolated for n=%d: %.0f .. %.0f compareXPointers calls, %.3fs .. %.3fs wall-clock " ..
            "(get_deleted_annotations only, based on per-size coefficients observed across n={%s})",
            target_n,
            lo_calls_c * target_n, hi_calls_c * target_n,
            lo_elapsed_c * target_n, hi_elapsed_c * target_n,
            table.concat(sizes, ",")
        ))
    end)
end)
