-- hk-scenario :: curated prop catalog
-- Categorised list of common scenario props. Extend freely — just add models
-- to a category's list (or add a new category). Searching matches both the
-- model name and the friendly label. Admins can also free-type any model that
-- isn't in this list via "Add prop (type model)".

ScnCatalog = {
    { category = 'Barriers & Blockers', icon = '🚧', props = {
        { model = 'prop_barrier_work05',      label = 'Work barrier (solid)' },
        { model = 'prop_barrier_work06a',     label = 'Work barrier (mesh)' },
        { model = 'prop_barrier_work06b',     label = 'Work barrier (long)' },
        { model = 'prop_mp_barrier_02b',      label = 'MP barrier' },
        { model = 'prop_mp_barrier_01',       label = 'MP barrier (short)' },
        { model = 'prop_barier_conc_01a',     label = 'Concrete barrier A' },
        { model = 'prop_barier_conc_02a',     label = 'Concrete barrier B' },
        { model = 'prop_barier_conc_05a',     label = 'Concrete + mesh' },
        { model = 'prop_fnclink_03gate5',     label = 'Chainlink gate' },
        { model = 'prop_sec_barier_02a',      label = 'Security boom gate' },
        { model = 'p_ld_stinger_s',           label = 'Stinger spike strip' },
    }},
    { category = 'Cones & Signs', icon = '🔺', props = {
        { model = 'prop_roadcone02a',         label = 'Road cone (large)' },
        { model = 'prop_roadcone01a',         label = 'Road cone (small)' },
        { model = 'prop_mp_cone_01',          label = 'MP cone' },
        { model = 'prop_barrier_wat_04',      label = 'Water barrier' },
        { model = 'prop_consign_02a',         label = 'Construction sign' },
        { model = 'prop_roadsign_stop',       label = 'Stop sign' },
        { model = 'prop_sign_road_restrict',  label = 'Road closed sign' },
        { model = 'prop_worklight_03b',       label = 'Work light stand' },
    }},
    { category = 'Police & Emergency', icon = '🚓', props = {
        { model = 'prop_barrier_work06a',     label = 'Police barrier' },
        { model = 'prop_police_id_screen',    label = 'Police ID screen' },
        { model = 'p_cs_clip_01_s',           label = 'Clipboard' },
        { model = 'prop_cs_cuffs_01',         label = 'Handcuffs' },
        { model = 'prop_tent_02',             label = 'Command tent' },
        { model = 'prop_gazebo_02',           label = 'Gazebo' },
        { model = 'prop_ecm_unit_01',         label = 'ECM unit' },
        { model = 'prop_flare_01',            label = 'Road flare' },
    }},
    { category = 'Construction', icon = '🏗️', props = {
        { model = 'prop_scaffold_01a',        label = 'Scaffold' },
        { model = 'prop_toolchest_01',        label = 'Tool chest' },
        { model = 'prop_cement_mixer01',      label = 'Cement mixer' },
        { model = 'prop_wheelbarrow02a',      label = 'Wheelbarrow' },
        { model = 'prop_bucket_01a',          label = 'Bucket' },
        { model = 'prop_ladder_01a',          label = 'Ladder' },
        { model = 'prop_generator_03b',       label = 'Generator' },
        { model = 'prop_barrel_pile_02',      label = 'Barrel pile' },
    }},
    { category = 'Crowd Control', icon = '🚸', props = {
        { model = 'prop_ld_rope_bollard',     label = 'Rope bollard post' },
        { model = 'p_ld_stinger_s',           label = 'Spike strip' },
        { model = 'prop_barrier_wat_01',      label = 'Water barrier (long)' },
        { model = 'prop_fnclink_05crd2',      label = 'Fence with tape' },
        { model = 'prop_cctv_pole_02',        label = 'CCTV pole' },
    }},
    { category = 'Lighting', icon = '💡', props = {
        { model = 'prop_worklight_01a',       label = 'Work light (single)' },
        { model = 'prop_worklight_02a',       label = 'Work light (double)' },
        { model = 'prop_generator_03b',       label = 'Light generator' },
        { model = 'prop_flood_lights_01a',    label = 'Flood lights' },
        { model = 'prop_air_lights_02a',      label = 'Airport light (red)' },
        { model = 'prop_air_lights_01a',      label = 'Airport light (green)' },
    }},
    { category = 'Furniture & Props', icon = '🪑', props = {
        { model = 'prop_table_03',            label = 'Table' },
        { model = 'prop_chair_01a',           label = 'Chair' },
        { model = 'prop_off_chair_01',        label = 'Office chair' },
        { model = 'prop_crate_02a',           label = 'Wooden crate' },
        { model = 'prop_boxpile_07d',         label = 'Cardboard boxes' },
        { model = 'prop_pallet_02a',          label = 'Pallet' },
        { model = 'prop_bin_07a',             label = 'Trash bin' },
        { model = 'prop_bench_01a',           label = 'Park bench' },
    }},
    { category = 'Containers & Storage', icon = '📦', props = {
        { model = 'prop_container_01a',       label = 'Shipping container' },
        { model = 'prop_contr_03b_ld',        label = 'Container (weathered)' },
        { model = 'prop_dumpster_01a',        label = 'Dumpster' },
        { model = 'prop_skip_01',             label = 'Skip bin' },
        { model = 'prop_toolchest_05',        label = 'Large tool chest' },
    }},
}
