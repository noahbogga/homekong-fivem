-- DPEmotes forked by TayMcKenzieNZ requires you to be on the latest FiveM Gamebuild for all emotes to function.
-- If an emote does not work, you may be on an older gamebuild.
-- To get a higher gamebuild, see ReadMe on github repositorty
DP = {}

DP.Expressions = {
   ["生氣"] = {"Expression", "mood_angry_1"},
   ["喝醉"] = {"Expression", "mood_drunk_1"},
   ["呆滯"] = {"Expression", "pose_injured_1"},
   ["抽蓄"] = {"Expression", "electrocuted_1"},
   ["暴躁"] = {"Expression", "effort_1"},
   ["暴躁2"] = {"Expression", "mood_drivefast_1"},
   ["暴躁3"] = {"Expression", "pose_angry_1"},
   ["開心"] = {"Expression", "mood_happy_1"},
   ["受傷"] = {"Expression", "mood_injured_1"},
   ["喜悅"] = {"Expression", "mood_dancing_low_1"},
   ["嘴巴呼吸"] = {"Expression", "smoking_hold_1"},
   ["永不眨眼"] = {"Expression", "pose_normal_1"},
   ["單眼"] = {"Expression", "pose_aiming_1"},
   ["震驚"] = {"Expression", "shocked_1"},
   ["震驚2"] = {"Expression", "shocked_2"},
   ["睡覺"] = {"Expression", "mood_sleeping_1"},
   ["睡覺2"] = {"Expression", "dead_1"},
   ["睡覺3"] = {"Expression", "dead_2"},
   ["飄飄然"] = {"Expression", "mood_smug_1"},
   ["很投機"] = {"Expression", "mood_aiming_1"},
   ["你有壓力"] = {"Expression", "mood_stressed_1"},
   ["悶悶不樂"] = {"Expression", "mood_sulk_1"},
   ["奇怪"] = {"Expression", "effort_2"},
   ["奇怪2"] = {"Expression", "effort_3"},
}

DP.Walks = {
   ["外星人"] = {"move_m@alien"},
   ["著重甲"] = {"anim_group_move_ballistic"},
   ["傲慢"] = {"move_f@arrogant@a"},
   ["勇敢"] = {"move_m@brave"},
   ["隨便"] = {"move_m@casual@a"},
   ["隨便2"] = {"move_m@casual@b"},
   ["隨便3"] = {"move_m@casual@c"},
   ["隨便4"] = {"move_m@casual@d"},
   ["隨便5"] = {"move_m@casual@e"},
   ["隨便6"] = {"move_m@casual@f"},
   ["懶係野"] = {"move_f@chichi"},
   ["自信"] = {"move_m@confident"},
   ["警察"] = {"move_m@business@a"},
   ["警察2"] = {"move_m@business@b"},
   ["警察3"] = {"move_m@business@c"},
   ["一般女性"] = {"move_f@multiplayer"},
   ["一般女男性"] = {"move_m@multiplayer"},
   ["喝醉酒"] = {"move_m@drunk@a"},
   ["少少飲醉"] = {"move_m@drunk@slightlydrunk"},
   ["喝醉酒2"] = {"move_m@buzzed"},
   ["喝醉酒3"] = {"move_m@drunk@verydrunk"},
   ["女性的"] = {"move_f@femme@"},
   ["Fire"] = {"move_characters@franklin@fire"},
   ["Fire2"] = {"move_characters@michael@fire"},
   ["Fire3"] = {"move_m@fire"},
   ["逃跑"] = {"move_f@flee@a"},
   ["Franklin"] = {"move_p_m_one"},
   ["黑幫"] = {"move_m@gangster@generic"},
   ["黑幫2"] = {"move_m@gangster@ng"},
   ["黑幫3"] = {"move_m@gangster@var_e"},
   ["黑幫4"] = {"move_m@gangster@var_f"},
   ["黑幫5"] = {"move_m@gangster@var_i"},
   ["Grooving"] = {"anim@move_m@grooving@"},
   ["保安"] = {"move_m@prison_gaurd"},
   ["手銬住左"] = {"move_m@prisoner_cuffed"},
   ["高踭鞋"] = {"move_f@heels@c"},
   ["高踭鞋2"] = {"move_f@heels@d"},
   ["行山友"] = {"move_m@hiking"},
   ["潮流尖端"] = {"move_m@hipster@a"},
   ["流浪漢"] = {"move_m@hobo@a"},
   ["趕時間"] = {"move_f@hurry@a"},
   ["清潔工"] = {"move_p_m_zero_janitor"},
   ["清潔工2"] = {"move_p_m_zero_slow"},
   ["緩跑"] = {"move_m@jog@"},
   ["Lemar"] = {"anim_group_move_lemar_alley"},
   ["Lester"] = {"move_heist_lester"},
   ["Lester2"] = {"move_lester_caneup"},
   ["Maneater"] = {"move_f@maneater"},
   ["Michael"] = {"move_ped_bucket"},
   ["有錢人"] = {"move_m@money"},
   ["大隻佬"] = {"move_m@muscle@a"},
   ["高貴男"] = {"move_m@posh@"},
   ["高貴女"] = {"move_f@posh@"},
   ["快步"] = {"move_m@quick"},
   ["跑手"] = {"female_fast_runner"},
   ["傷心"] = {"move_m@sad@a"},
   ["厚臉皮"] = {"move_m@sassy"},
   ["厚臉皮2"] = {"move_f@sassy"},
   ["受驚"] = {"move_f@scared"},
   ["性感"] = {"move_f@sexy@a"},
   ["陰陰濕濕"] = {"move_m@shadyped@a"},
   ["慢行"] = {"move_characters@jimmy@slow@"},
   ["Swagger"] = {"move_m@swagger"},
   ["硬漢"] = {"move_m@tough_guy@"},
   ["硬漢2"] = {"move_f@tough_guy@"},
   ["收垃圾"] = {"clipset@move@trash_fast_turn"},
   ["收垃圾2"] = {"missfbi4prepp1_garbageman"},
   ["Trevor"] = {"move_p_m_two"},
   ["Wide"] = {"move_m@bag"},
   -- I cant get these to work for some reason, if anyone knows a fix lmk
   --["Caution"] = {"move_m@caution"},
   --["Chubby"] = {"anim@move_m@chubby@a"},
   --["Crazy"] = {"move_m@crazy"},
   --["Joy"] = {"move_m@joy@a"},
   --["Power"] = {"move_m@power"},
   --["Sad2"] = {"anim@move_m@depression@a"},
   --["Sad3"] = {"move_m@depression@b"},
   --["Sad4"] = {"move_m@depression@d"},
   --["Wading"] = {"move_m@wading"},
}

DP.Shared = {
   --[emotename] = {dictionary, animation, displayname, targetemotename, additionalanimationoptions}
   -- you dont have to specify targetemoteanem, if you do dont it will just play the same animation on both.
   -- targetemote is used for animations that have a corresponding animation to the other player.
   ["handshake"] = {"mp_ped_interaction", "handshake_guy_a", "握手", "handshake2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3000,
      SyncOffsetFront = 0.9
   }},
   ["handshake2"] = {"mp_ped_interaction", "handshake_guy_b", "握手 2", "handshake", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3000
   }},
   ["hug"] = {"mp_ped_interaction", "kisses_guy_a", "擁抱", "hug2", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteDuration = 5000,
      SyncOffsetFront = 1.05,
   }},
   ["hug2"] = {"mp_ped_interaction", "kisses_guy_b", "擁抱 2", "hug", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteDuration = 5000,
      SyncOffsetFront = 1.13
   }},
   ["hug3"] = {"misscarsteal2chad_goodbye", "chad_armsaround_chad", "擁抱 3", "hug4", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
      SyncOffsetFront = 0.05,
   }},
   ["hug4"] = {"misscarsteal2chad_goodbye", "chad_armsaround_girl", "擁抱 4", "hug3", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
      SyncOffsetFront = 0.13
   }},
   ["kiss"] = {"mp_ped_interaction", "kisses_guy_a", "錫錫", "kiss2", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteDuration = 5000,
      SyncOffsetFront = 1.05,
   }},
   ["kiss2"] = {"mp_ped_interaction", "kisses_guy_b", "錫錫 2", "kiss", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteDuration = 5000,
      SyncOffsetFront = 1.13
   }},
   ["bro"] = {"mp_ped_interaction", "hugs_guy_a", "Bro", "bro2", AnimationOptions =
   {
      SyncOffsetFront = 1.14
   }},
   ["bro2"] = {"mp_ped_interaction", "hugs_guy_b", "Bro 2", "bro", AnimationOptions =
   {
      SyncOffsetFront = 1.14
   }},
   ["give"] = {"mp_common", "givetake1_a", "俾野人", "give2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 2000
   }},
   ["give2"] = {"mp_common", "givetake1_b", "俾野人 2", "give", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 2000
   }},
   ["baseball"] = {"anim@arena@celeb@flat@paired@no_props@", "baseball_a_player_a", "打棒球", "baseballthrow"},
   ["baseballthrow"] = {"anim@arena@celeb@flat@paired@no_props@", "baseball_a_player_b", "丟棒球", "baseball"},
   ["stickup"] = {"random@countryside_gang_fight", "biker_02_stickup_loop", "Stick Up", "stickupscared", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["stickupscared"] = {"missminuteman_1ig_2", "handsup_base", "Stickup Scared", "stickup", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["punch"] = {"melee@unarmed@streamed_variations", "plyr_takedown_rear_lefthook", "揼人", "punched"},
   ["punched"] = {"melee@unarmed@streamed_variations", "victim_takedown_front_cross_r", "被人揼", "punch"},
   ["headbutt"] = {"melee@unarmed@streamed_variations", "plyr_takedown_front_headbutt", "頭槌", "headbutted"},
   ["headbutted"] = {"melee@unarmed@streamed_variations", "victim_takedown_front_headbutt", "被頭槌", "headbutt"},
   ["slap2"] = {"melee@unarmed@streamed_variations", "plyr_takedown_front_backslap", "打人一巴 2", "slapped2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
      EmoteDuration = 2000,
   }},
   ["slap"] = {"melee@unarmed@streamed_variations", "plyr_takedown_front_slap", "打人一巴", "slapped", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
      EmoteDuration = 2000,
   }},
   ["slapped"] = {"melee@unarmed@streamed_variations", "victim_takedown_front_slap", "被打一巴", "slap"},
   ["slapped2"] = {"melee@unarmed@streamed_variations", "victim_takedown_front_backslap", "被打一巴 2", "slap2"},
   ["receiveblowjob"] = {"misscarsteal2pimpsex", "pimpsex_punter", "Receive Blowjob", "Give Blowjob", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteDuration = 30000,
      SyncOffsetFront = 0.63
   }},
   ["giveblowjob"] = {"misscarsteal2pimpsex", "pimpsex_hooker", "Give Blowjob", "Receive Blowjob", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteDuration = 30000,
      SyncOffsetFront = 0.63
   }},
   ["streetsexmale"] = {"misscarsteal2pimpsex", "shagloop_pimp", "Street Sex Male", "Street Sex Female", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
      SyncOffsetFront = 0.50
   }},
   ["streetsexfemale"] = {"misscarsteal2pimpsex", "shagloop_hooker", "Street Sex Female", "Street Sex Male", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
      SyncOffsetFront = -0.50
   }},
}

DP.Dances = {
   ["dance"] = {"anim@amb@nightclub@dancers@podium_dancers@", "hi_dance_facedj_17_v2_male^5", "Dance", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dance2"] = {"anim@amb@nightclub@mini@dance@dance_solo@male@var_b@", "high_center_down", "Dance 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dance3"] = {"anim@amb@nightclub@mini@dance@dance_solo@male@var_a@", "high_center", "Dance 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dance4"] = {"anim@amb@nightclub@mini@dance@dance_solo@male@var_b@", "high_center_up", "Dance 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dance5"] = {"anim@amb@casino@mini@dance@dance_solo@female@var_a@", "med_center", "Dance 5", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["dance6"] = {"misschinese2_crystalmazemcs1_cs", "dance_loop_tao", "Dance 6", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dance7"] = {"misschinese2_crystalmazemcs1_ig", "dance_loop_tao", "Dance 7", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dance8"] = {"missfbi3_sniping", "dance_m_default", "Dance 8", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dance9"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_a@", "med_center_up", "Dance 9", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancef"] = {"anim@amb@nightclub@dancers@solomun_entourage@", "mi_dance_facedj_17_v1_female^1", "Dance F", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancef2"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_a@", "high_center", "Dance F2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancef3"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_a@", "high_center_up", "Dance F3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancef4"] = {"anim@amb@nightclub@dancers@crowddance_facedj@hi_intensity", "hi_dance_facedj_09_v2_female^1", "Dance F4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancef5"] = {"anim@amb@nightclub@dancers@crowddance_facedj@hi_intensity", "hi_dance_facedj_09_v2_female^3", "Dance F5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancef6"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_a@", "high_center_up", "Dance F6", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["danceclub"] = {"anim@amb@nightclub_island@dancers@beachdance@", "hi_idle_a_m03", "Dance Club", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["danceclub2"] = {"anim@amb@nightclub_island@dancers@beachdance@", "hi_idle_a_m05", "Dance Club 2", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["danceclub3"] = {"anim@amb@nightclub_island@dancers@beachdance@", "hi_idle_a_m02", "Dance Club 3", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["danceclub4"] = {"anim@amb@nightclub_island@dancers@beachdance@", "hi_idle_b_f01", "Dance Club 4", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["danceclub5"] = {"anim@amb@nightclub_island@dancers@club@", "hi_idle_a_f02", "Dance Club 5", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["danceclub6"] = {"anim@amb@nightclub_island@dancers@club@", "hi_idle_b_m03", "Dance Club 6", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["danceclub7"] = {"anim@amb@nightclub_island@dancers@club@", "hi_idle_d_f01", "Dance Club 7", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["bsdrink"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "BS Drink", AnimationOptions =
   {
       Prop = 'prop_food_bs_juice02',
       PropBone = 28422,
       PropPlacement = {0.02, 0.0, -0.10, 0.0, 0.0, -0.50},
       EmoteLoop = true,
       EmoteMoving = true,
   }},
   ["fries"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger", "Fries", AnimationOptions =
   {
       Prop = 'prop_food_bs_chips',
       PropBone = 60309,
       PropPlacement = { -0.0100, 0.0200, -0.0100, -175.1935, 97.6975, 13.9598 },
       EmoteMoving = true,
   }},
   ["fbbq"] = {"amb@prop_human_bbq@male@idle_a", "idle_b", "fbbq", AnimationOptions =
   {
       Prop = "prop_fish_slice_01",
       PropBone = 28422,
       PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
       --
       EmoteLoop = true,
       EmoteMoving = false,
   }},
   ["dancedrink"] = {"anim@amb@nightclub_island@dancers@beachdanceprop@", "mi_idle_c_m01", "Dance Drink (Beer)", AnimationOptions =
   {
      Prop = 'prop_beer_amopen',
      PropBone = 28422,
      PropPlacement = {0.0, 0.00,0.0, 0.0, 0.0, 20.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dancedrink2"] = {"anim@amb@nightclub_island@dancers@beachdanceprop@", "mi_loop_f1", "Dance Drink 2 (Wine)", AnimationOptions =
   {
      Prop = 'p_wine_glass_s',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0,-0.0900, 0.0, 0.0, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dancedrink3"] = {"anim@amb@nightclub_island@dancers@beachdanceprop@", "mi_loop_m04", "Dance Drink 3 (Whiskey)", AnimationOptions =
   {
      Prop = 'ba_prop_battle_whiskey_opaque_s',
      PropBone = 28422,
      PropPlacement = {-0.0100, 0.00,0.0, 0.0, 0.0, 10.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dancedrink4"] = {"anim@amb@nightclub_island@dancers@beachdanceprops@male@", "mi_idle_b_m04", "Dance Drink 4 (Whiskey)", AnimationOptions =
   {
      Prop = 'ba_prop_battle_whiskey_opaque_s',
      PropBone = 28422,
      PropPlacement = {-0.0100, 0.00,0.0, 0.0, 0.0, 10.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dancedrink5"] = {"anim@amb@nightclub_island@dancers@crowddance_single_props@", "hi_dance_prop_09_v1_female^3", "Dance Drink 5 (Wine)", AnimationOptions =
   {
      Prop = 'p_wine_glass_s',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0,-0.0900, 0.0, 0.0, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dancedrink6"] = {"anim@amb@nightclub_island@dancers@crowddance_single_props@", "hi_dance_prop_09_v1_male^3", "Dance Drink 6 (Beer)", AnimationOptions =
   {
      Prop = 'prop_beer_logopen',
      PropBone = 28422,
      PropPlacement = {0.0090, 0.0010,-0.0310, 180.0, 180.0, -69.99},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dancedrink7"] = {"anim@amb@nightclub_island@dancers@crowddance_single_props@", "hi_dance_prop_11_v1_female^3", "Dance Drink 7 (Wine)", AnimationOptions =
   {
      Prop = 'p_wine_glass_s',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0,-0.0900, 0.0, 0.0, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dancedrink8"] = {"anim@amb@nightclub_island@dancers@crowddance_single_props@", "hi_dance_prop_11_v1_female^1", "Dance Drink 8 (Wine)", AnimationOptions =
   {
      Prop = 'p_wine_glass_s',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0,-0.0900, 0.0, 0.0, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["danceslow2"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_a@", "low_center", "Dance Slow 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["danceslow3"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_a@", "low_center_down", "Dance Slow 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["danceslow4"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_b@", "low_center", "Dance Slow 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["danceupper"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_b@", "high_center", "Dance Upper", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["danceupper2"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_b@", "high_center_up", "Dance Upper 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["danceshy"] = {"anim@amb@nightclub@mini@dance@dance_solo@male@var_a@", "low_center", "Dance Shy", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["danceshy2"] = {"anim@amb@nightclub@mini@dance@dance_solo@female@var_b@", "low_center_down", "Dance Shy 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["danceslow"] = {"anim@amb@nightclub@mini@dance@dance_solo@male@var_b@", "low_center", "Dance Slow", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancesilly9"] = {"rcmnigel1bnmt_1b", "dance_loop_tyler", "Dance Silly 9", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancesilly"] = {"special_ped@mountain_dancer@monologue_3@monologue_3a", "mnt_dnc_buttwag", "Dance Silly", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancesilly2"] = {"move_clown@p_m_zero_idles@", "fidget_short_dance", "Dance Silly 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancesilly3"] = {"move_clown@p_m_two_idles@", "fidget_short_dance", "Dance Silly 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancesilly4"] = {"anim@amb@nightclub@lazlow@hi_podium@", "danceidle_hi_11_buttwiggle_b_laz", "Dance Silly 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancesilly5"] = {"timetable@tracy@ig_5@idle_a", "idle_a", "Dance Silly 5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancesilly6"] = {"timetable@tracy@ig_8@idle_b", "idle_d", "Dance Silly 6", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["dancesilly8"] = {"anim@mp_player_intcelebrationfemale@the_woogie", "the_woogie", "Dance Silly 8", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["dancesilly7"] = {"anim@amb@casino@mini@dance@dance_solo@female@var_b@", "high_center", "Dance Silly 7", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["danceglowstick"] = {"anim@amb@nightclub@lazlow@hi_railing@", "ambclub_13_mi_hi_sexualgriding_laz", "Dance Glowsticks", AnimationOptions =
   {
      Prop = 'ba_prop_battle_glowstick_01',
      PropBone = 28422,
      PropPlacement = {0.0700,0.1400,0.0,-80.0,20.0},
      SecondProp = 'ba_prop_battle_glowstick_01',
      SecondPropBone = 60309,
      SecondPropPlacement = {0.0700,0.0900,0.0,-120.0,-20.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["danceglowstick2"] = {"anim@amb@nightclub@lazlow@hi_railing@", "ambclub_12_mi_hi_bootyshake_laz", "Dance Glowsticks 2", AnimationOptions =
   {
      Prop = 'ba_prop_battle_glowstick_01',
      PropBone = 28422,
      PropPlacement = {0.0700,0.1400,0.0,-80.0,20.0},
      SecondProp = 'ba_prop_battle_glowstick_01',
      SecondPropBone = 60309,
      SecondPropPlacement = {0.0700,0.0900,0.0,-120.0,-20.0},
      EmoteLoop = true,
   }},
   ["danceglowstick3"] = {"anim@amb@nightclub@lazlow@hi_railing@", "ambclub_09_mi_hi_bellydancer_laz", "Dance Glowsticks 3", AnimationOptions =
   {
      Prop = 'ba_prop_battle_glowstick_01',
      PropBone = 28422,
      PropPlacement = {0.0700,0.1400,0.0,-80.0,20.0},
      SecondProp = 'ba_prop_battle_glowstick_01',
      SecondPropBone = 60309,
      SecondPropPlacement = {0.0700,0.0900,0.0,-120.0,-20.0},
      EmoteLoop = true,
   }},
   ["dancehorse"] = {"anim@amb@nightclub@lazlow@hi_dancefloor@", "dancecrowd_li_15_handup_laz", "Dance Horse", AnimationOptions =
   {
      Prop = "ba_prop_battle_hobby_horse",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["dancehorse2"] = {"anim@amb@nightclub@lazlow@hi_dancefloor@", "crowddance_hi_11_handup_laz", "Dance Horse 2", AnimationOptions =
   {
      Prop = "ba_prop_battle_hobby_horse",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["dancehorse3"] = {"anim@amb@nightclub@lazlow@hi_dancefloor@", "dancecrowd_li_11_hu_shimmy_laz", "Dance Horse 3", AnimationOptions =
   {
      Prop = "ba_prop_battle_hobby_horse",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["dj"] = {"anim@amb@nightclub@djs@dixon@", "dixn_dance_cntr_open_dix", "DJ", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["dj2"] = {"anim@amb@nightclub@djs@solomun@", "sol_idle_ctr_mid_a_sol", "DJ 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dj3"] = {"anim@amb@nightclub@djs@solomun@", "sol_dance_l_sol", "DJ 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dj4"] = {"anim@amb@nightclub@djs@black_madonna@", "dance_b_idle_a_blamadon", "DJ 4", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dj5"] = {"anim@amb@nightclub@djs@dixon@", "dixn_end_dix", "DJ 5", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dj5"] = {"anim@amb@nightclub@djs@dixon@", "dixn_idle_cntr_a_dix", "DJ 5", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dj6"] = {"anim@amb@nightclub@djs@dixon@", "dixn_idle_cntr_b_dix", "DJ 6", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dj7"] = {"anim@amb@nightclub@djs@dixon@", "dixn_idle_cntr_g_dix", "DJ 7", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dj8"] = {"anim@amb@nightclub@djs@dixon@", "dixn_idle_cntr_gb_dix", "DJ 8", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["dj9"] = {"anim@amb@nightclub@djs@dixon@", "dixn_sync_cntr_j_dix", "DJ 9", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["twerk"] = {"switch@trevor@mocks_lapdance", "001443_01_trvs_28_idle_stripper", "Twerk", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapdance"] = {"mp_safehouse", "lap_dance_girl", "Lapdance"},
   ["lapdance2"] = {"mini@strip_club@private_dance@idle", "priv_dance_idle", "Lapdance 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapdance3"] = {"mini@strip_club@private_dance@part1", "priv_dance_p1", "Lapdance 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapdance4"] = {"mini@strip_club@private_dance@part2", "priv_dance_p2", "Lapdance 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapdance5"] = {"mini@strip_club@private_dance@part3", "priv_dance_p3", "Lapdance 5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapdance6"] = {"oddjobs@assassinate@multi@yachttarget@lapdance", "yacht_ld_f", "Lapdance 6", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapdancewith"] = {"mini@strip_club@lap_dance_2g@ld_2g_p3", "ld_2g_p3_s2", "Lapdance With", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapdancewith2"] = {"mini@strip_club@lap_dance_2g@ld_2g_p2", "ld_2g_p2_s2", "Lapdance With2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapdancewith3"] = {"mini@strip_club@lap_dance_2g@ld_2g_p1", "ld_2g_p1_s2", "Lapdance With3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapchair"] = {"mini@strip_club@lap_dance@ld_girl_a_song_a_p1", "ld_girl_a_song_a_p1_f", "Lap Chair", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapchair2"] = {"mini@strip_club@lap_dance@ld_girl_a_song_a_p2", "ld_girl_a_song_a_p2_f", "Lap Chair2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lapchair3"] = {"mini@strip_club@lap_dance@ld_girl_a_song_a_p3", "ld_girl_a_song_a_p3_f", "Lap Chair3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
}

DP.AnimalEmotes = {
   ["bdogbark"] = {"creatures@rottweiler@amb@world_dog_barking@idle_a", "idle_a", "Bark (big dog)", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["bdogbeg"] = {"creatures@rottweiler@tricks@", "beg_loop", "Beg (big dog)", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["bdogbeg2"] = {"creatures@rottweiler@tricks@", "paw_right_loop", "Beg 2 (big dog)", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["bdogdump"] = {"creatures@rottweiler@move", "dump_loop", "Dump (big dog)", AnimationOptions =
   {
      Prop = 'prop_big_shit_02',
      PropBone = 51826,
      PropPlacement = {0.0,0.2000,-0.4600,0.0,-20.00, 0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["bdogitch"] = {"creatures@rottweiler@amb@world_dog_sitting@idle_a", "idle_a", "Itch (big dog)", AnimationOptions =
   {
      EmoteDuration = 2000
   }},
   ["bdogsleep"] = {"creatures@rottweiler@amb@sleep_in_kennel@", "sleep_in_kennel", "Sleep (big dog)", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["bdogsit"] = {"creatures@rottweiler@amb@world_dog_sitting@base", "base", "Sit (big dog)", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["bdogpee"] = {"creatures@rottweiler@move", "pee_left_idle", "Pee (big dog)", AnimationOptions =
   {
      EmoteLoop = false
   }},
   ["bdogpee2"] = {"creatures@rottweiler@move", "pee_right_idle", "Pee 2 (big dog)", AnimationOptions =
   {
      EmoteLoop = false
   }},
   ["sdogbark"] = {"creatures@pug@amb@world_dog_barking@idle_a", "idle_a", "Bark (small dog)", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["sdogitch"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_a", "Itch (small dog)", AnimationOptions =
   {
      EmoteDuration = 2000
   }},
   ["sdogsit"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_b", "Sit (small dog)", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["sdogld"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_c", "Lay Down (small dog)", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogshake"] = {"creatures@pug@amb@world_dog_barking@idle_a", "idle_c", "Shake (small dog)", AnimationOptions =
   {
      EmoteLoop = true
   }},
   ["sdogdance"] = {"creatures@pug@move", "idle_turn_0", "Dance (small dog)", AnimationOptions =
   {
      Prop = 'ba_prop_battle_glowstick_01',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.0300,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogdance2"] = {"creatures@pug@move", "idle_turn_0", "Dance 2 (small dog)", AnimationOptions =
   {
      Prop = 'ba_prop_battle_glowstick_01',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.0300,0.0,0.0,0.0},
      SecondProp = 'prop_cs_sol_glasses',
      SecondPropBone = 31086,
      SecondPropPlacement = {0.0500, 0.0300, 0.000, -100.0000003, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogbb"] = {"creatures@pug@move", "nill", "Baseball (small dog)", AnimationOptions =
   {
      Prop = 'w_am_baseball',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.0500,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogburger"] = {"creatures@pug@move", "nill", "Burger (small dog)", AnimationOptions =
   {
      Prop = 'prop_cs_burger_01',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.0400,0.0000,-90.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogcontroller"] = {"creatures@pug@move", "nill", "Controller (small dog)", AnimationOptions =
   {
      Prop = 'prop_controller_01',
      PropBone = 31086,
      PropPlacement = {0.1800,-0.0300,0.0000,-180.000,90.0000, 0.0000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogdolla"] = {"creatures@pug@move", "nill", "Dollar Bill (small dog)", AnimationOptions =
   {
      Prop = 'p_banknote_onedollar_s',
      PropBone = 31086,
      PropPlacement = {0.1700,-0.0100,0.0000,90.0000, 0.0000, 0.000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogdolla2"] = {"creatures@pug@move", "nill", "Dollar Bill Scrunched  (small dog)", AnimationOptions =
   {
      Prop = 'bkr_prop_scrunched_moneypage',
      PropBone = 31086,
      PropPlacement = {0.1700,0.000,0.0000,90.0000,00.0000, 00.0000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogdolla3"] = {"creatures@pug@move", "nill", "Money Stack  (small dog)", AnimationOptions =
   {
      Prop = 'bkr_prop_money_wrapped_01',
      PropBone = 31086,
      PropPlacement = {0.1700,-0.0100,0.0000,90.0000, 0.0000, 0.000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogdolla4"] = {"creatures@pug@move", "nill", "Money Bag  (small dog)", AnimationOptions =
   {
      Prop = 'ch_prop_ch_moneybag_01a',
      PropBone = 31086,
      PropPlacement = {0.1200,-0.2000,0.0000,-79.9999997,90.00, 0.0000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogmic"] = {"creatures@pug@move", "nill", "Microphone (small dog)", AnimationOptions =
   {
      Prop = 'p_ing_microphonel_01',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.0170,0.0300,0.000,0.0000, 0.0000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogteddy"] = {"creatures@pug@move", "nill", "Teddy (small dog)", AnimationOptions =
   {
      Prop = 'v_ilev_mr_rasberryclean',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.1100,-0.23,0.000,0.0000, 0.0000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogteddy2"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_b", "Teddy 2 (small dog)", AnimationOptions =
   {
      Prop = 'v_ilev_mr_rasberryclean',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.1100,-0.23,0.000,0.0000, 0.0000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogtennis"] = {"creatures@pug@move", "nill", "Tennis Ball (small dog)", AnimationOptions =
   {
      Prop = 'prop_tennis_ball',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.0600,0.0,0.0,0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogtennisr"] = {"creatures@pug@move", "nill", "Tennis Racket (small dog)", AnimationOptions =
   {
      Prop = 'prop_tennis_rack_01',
      PropBone = 31086,
      PropPlacement = {0.1500,-0.0200,0.00,0.000,0.0000, -28.0000},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogrose"] = {"creatures@pug@move", "nill", "Rose (small dog)", AnimationOptions =
   {
      Prop = 'prop_single_rose',
      PropBone = 12844,
      PropPlacement = {0.1090,-0.0140,0.0500,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogrose2"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_b", "Rose Sit (small dog)", AnimationOptions =
   {
      Prop = 'prop_single_rose',
      PropBone = 12844,
      PropPlacement = {0.1090,-0.0140,0.0500,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogggun"] = {"creatures@pug@move", "nill", "Gun Gold (small dog)", AnimationOptions =
   {
      Prop = 'w_pi_pistol_luxe',
      PropBone = 12844,
      PropPlacement = {0.2010,-0.0080,0.0,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoggun2"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_b", "Gun Gold Sit (small dog)", AnimationOptions =
   {
      Prop = 'w_pi_pistol_luxe',
      PropBone = 12844,
      PropPlacement = {0.2010,-0.0080,0.0,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogstun"] = {"creatures@pug@move", "nill", "Stun Gun (small dog)", AnimationOptions =
   {
      Prop = 'w_pi_stungun',
      PropBone = 12844,
      PropPlacement = {0.1400,-0.0100,0.0,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
      PtfxAsset = "core",
      PtfxName = "blood_stungun",
      PtfxPlacement = {0.208, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0},
      PtfxInfo = Config.Languages[Config.MenuLanguage]['stun'],
      PtfxWait = 200,
   }},
   ["sdoggl1"] = {"creatures@pug@move", "nill", "Aviators (small dog)", AnimationOptions =
   {
      Prop = 'prop_aviators_01',
      PropBone = 31086,
      PropPlacement = {0.0500, 0.0400, 0.000, -90.00, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoggl2"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_b", "Aviators Sitting (small dog)", AnimationOptions =
   {
      Prop = 'prop_aviators_01',
      PropBone = 31086,
      PropPlacement = {0.0500, 0.0400, 0.000, -90.00, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoggl3"] = {"creatures@pug@move", "nill", "Sunglasses (small dog)", AnimationOptions =
   {
      Prop = 'prop_cs_sol_glasses',
      PropBone = 31086,
      PropPlacement = {0.0500, 0.0300, 0.000, -100.0000003, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoggl4"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_b", "Sunglasses Sitting (small dog)", AnimationOptions =
   {
      Prop = 'prop_cs_sol_glasses',
      PropBone = 31086,
      PropPlacement = {0.0500, 0.0300, 0.000, -100.0000003, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoghd1"] = {"creatures@pug@move", "nill", "Hot Dog (small dog)", AnimationOptions =
   {
      Prop = 'prop_cs_hotdog_01',
      PropBone = 31086,
      PropPlacement = {0.1300, -0.0250, 0.000, -88.272053, -9.8465858, -0.1488562},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoghd2"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_b", "Hot Dog Sitting (small dog)", AnimationOptions =
   {
      Prop = 'prop_cs_hotdog_01',
      PropBone = 31086,
      PropPlacement = {0.1300, -0.0250, 0.000, -88.272053, -9.8465858, -0.1488562},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoghlmt1"] = {"creatures@pug@move", "nill", "Helmet 1 (small dog)", AnimationOptions =
   {
      Prop = 'ba_prop_battle_sports_helmet',
      PropBone = 31086,
      PropPlacement = {0.00, -0.0200, 0.000, -90.00, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoghlmt2"] = {"creatures@pug@move", "nill", "Helmet 2 (small dog)", AnimationOptions =
   {
      Prop = 'prop_hard_hat_01',
      PropBone = 31086,
      PropPlacement = {0.00, 0.1300, 0.000, -90.00, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoghat"] = {"creatures@pug@move", "nill", "Hat 1 (small dog)", AnimationOptions =
   {
      Prop = 'prop_proxy_hat_01',
      PropBone = 31086,
      PropPlacement = {0.0, 0.1200, 0.000, -99.8510766, 80.1489234, 1.7279411},
      SecondProp = 'prop_aviators_01',
      SecondPropBone = 31086,
      SecondPropPlacement = {0.0500, 0.0400, 0.000, -90.00, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdoghat2"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_b", "Hat 2 Sitting (small dog)", AnimationOptions =
   {
      Prop = 'prop_proxy_hat_01',
      PropBone = 31086,
      PropPlacement = {0.0, 0.1200, 0.000, -99.8510766, 80.1489234, 1.7279411},
      SecondProp = 'prop_aviators_01',
      SecondPropBone = 31086,
      SecondPropPlacement = {0.0500, 0.0400, 0.000, -90.00, 90.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogsteak"] = {"creatures@pug@move", "nill", "Steak (small dog)", AnimationOptions =
   {
      Prop = 'prop_cs_steak',
      PropBone = 31086,
      PropPlacement = {0.1800, -0.0200, 0.000, 90.00, 0.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["sdogsteak2"] = {"creatures@pug@amb@world_dog_sitting@idle_a", "idle_c", "Steak 2 Lay Down (small dog)", AnimationOptions =
   {
      Prop = 'prop_cs_steak',
      PropBone = 31086,
      PropPlacement = {0.1800, -0.0200, 0.000, 90.00, 0.00, 0.00},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
}

DP.Emotes = {
   ["drink"] = {"mp_player_intdrink", "loop_bottle", "Drink", AnimationOptions =
   {
        Prop = "prop_ld_flow_bottle",
        PropBone = 18905,
        PropPlacement = {0.12, 0.008, 0.03, 240.0, -60.0},
        EmoteMoving = true,
        EmoteLoop = true,
   }},
   ["dispenser"] = {"mini@sprunk", "plyr_buy_drink_pt1", "Dispenser", AnimationOptions =
   {
        EmoteMoving = false,
        EmoteLoop = false,
   }},
   ["beast"] = {"anim@mp_fm_event@intro", "beast_transform", "Beast", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 5000,
   }},
   ["chill"] = {"switch@trevor@scares_tramp", "trev_scares_tramp_idle_tramp", "Chill", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["cloudgaze"] = {"switch@trevor@annoys_sunbathers", "trev_annoys_sunbathers_loop_girl", "躺地望白雲", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["cloudgaze2"] = {"switch@trevor@annoys_sunbathers", "trev_annoys_sunbathers_loop_guy", "躺地望白雲 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["prone"] = {"missfbi3_sniping", "prone_dave", "趴低", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["pullover"] = {"misscarsteal3pullover", "pull_over_right", "Pullover", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 1300,
   }},
   ["idle"] = {"anim@heists@heist_corona@team_idles@male_a", "idle", "空閒", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idle8"] = {"amb@world_human_hang_out_street@male_b@idle_a", "idle_b", "空閒 8"},
   ["idle9"] = {"friends@fra@ig_1", "base_idle", "空閒 9", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idle10"] = {"mp_move@prostitute@m@french", "idle", "空閒 10", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["idle11"] = {"random@countrysiderobbery", "idle_a", "空閒 11", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idle2"] = {"anim@heists@heist_corona@team_idles@female_a", "idle", "空閒 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idle3"] = {"anim@heists@humane_labs@finale@strip_club", "ped_b_celebrate_loop", "空閒 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idle4"] = {"anim@mp_celebration@idles@female", "celebration_idle_f_a", "空閒 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idle5"] = {"anim@mp_corona_idles@female_b@idle_a", "idle_a", "空閒 5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idle6"] = {"anim@mp_corona_idles@male_c@idle_a", "idle_a", "空閒 6", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idle7"] = {"anim@mp_corona_idles@male_d@idle_a", "idle_a", "空閒 7", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idledrunk"] = {"random@drunk_driver_1", "drunk_driver_stand_loop_dd1", "空閒並飲醉", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idledrunk2"] = {"random@drunk_driver_1", "drunk_driver_stand_loop_dd2", "空閒並飲醉 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["idledrunk3"] = {"missarmenian2", "standing_idle_loop_drunk", "空閒並飲醉 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["airguitar"] = {"anim@mp_player_intcelebrationfemale@air_guitar", "air_guitar", "空氣結他"},
   ["airsynth"] = {"anim@mp_player_intcelebrationfemale@air_synth", "air_synth", "空氣DJ"},
   ["argue"] = {"misscarsteal4@actor", "actor_berating_loop", "嘈交", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["argue2"] = {"oddjobs@assassinate@vice@hooker", "argue_a", "嘈交 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["bartender"] = {"anim@amb@clubhouse@bar@drink@idle_a", "idle_a_bartender", "Bartender", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["blowkiss"] = {"anim@mp_player_intcelebrationfemale@blow_kiss", "blow_kiss", "飛吻"},
   ["blowkiss2"] = {"anim@mp_player_intselfieblow_kiss", "exit", "飛吻 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 2000

   }},
   ["curtsy"] = {"anim@mp_player_intcelebrationpaired@f_f_sarcastic", "sarcastic_left", "屈膝禮"},
   ["bringiton"] = {"misscommon@response", "bring_it_on", "放馬過來", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3000
   }},
   ["comeatmebro"] = {"mini@triathlon", "want_some_of_this", "黎郁我呀", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 2000
   }},
   ["cop2"] = {"anim@amb@nightclub@peds@", "rcmme_amanda1_stand_loop_cop", "警察 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["cop3"] = {"amb@code_human_police_investigate@idle_a", "idle_b", "警察 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["crossarms"] = {"amb@world_human_hang_out_street@female_arms_crossed@idle_a", "idle_a", "翹埋雙手", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["crossarms2"] = {"amb@world_human_hang_out_street@male_c@idle_a", "idle_b", "翹埋雙手 2", AnimationOptions =
   {
      EmoteMoving = true,
   }},
   ["crossarms3"] = {"anim@heists@heist_corona@single_team", "single_team_loop_boss", "翹埋雙手 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["crossarms4"] = {"random@street_race", "_car_b_lookout", "翹埋雙手 4", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["crossarms5"] = {"anim@amb@nightclub@peds@", "rcmme_amanda1_stand_loop_cop", "翹埋雙手 5", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foldarms2"] = {"anim@amb@nightclub@peds@", "rcmme_amanda1_stand_loop_cop", "翹起雙手 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["crossarms6"] = {"random@shop_gunstore", "_idle", "翹埋雙手 6", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foldarms"] = {"anim@amb@business@bgen@bgen_no_work@", "stand_phone_phoneputdown_idle_nowork", "翹起雙手", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["crossarmsside"] = {"rcmnigel1a_band_groupies", "base_m2", "翹埋雙手 側面", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["damn"] = {"gestures@m@standing@casual", "gesture_damn", "Damn", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 1000
   }},
   ["damn2"] = {"anim@am_hold_up@male", "shoplift_mid", "Damn 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 1000
   }},
   ["pointdown"] = {"gestures@f@standing@casual", "gesture_hand_down", "Point Down", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 1000
   }},
   ["surrender"] = {"random@arrests@busted", "idle_a", "投降", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["surrender2"] = {"mp_bank_heist_1", "f_cower_02", "投降 2", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["surrender3"] = {"mp_bank_heist_1", "m_cower_01", "投降 3", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["surrender4"] = {"mp_bank_heist_1", "m_cower_02", "投降 4", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["surrender5"] = {"random@arrests", "kneeling_arrest_idle", "投降 5", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["surrender6"] = {"rcmbarry", "m_cower_01", "投降 6", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["facepalm2"] = {"anim@mp_player_intcelebrationfemale@face_palm", "face_palm", "Facepalm 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 8000
   }},
   ["facepalm"] = {"random@car_thief@agitated@idle_a", "agitated_idle_a", "Facepalm", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 8000
   }},
   ["facepalm3"] = {"missminuteman_1ig_2", "tasered_2", "Facepalm 3", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 8000
   }},
   ["facepalm4"] = {"anim@mp_player_intupperface_palm", "idle_a", "Facepalm 4", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["fallover"] = {"random@drunk_driver_1", "drunk_fall_over", "Fall Over"},
   ["fallover2"] = {"mp_suicide", "pistol", "Fall Over 2"},
   ["fallover3"] = {"mp_suicide", "pill", "Fall Over 3"},
   ["fallover4"] = {"friends@frf@ig_2", "knockout_plyr", "Fall Over 4"},
   ["fallover5"] = {"anim@gangops@hostage@", "victim_fail", "Fall Over 5"},
   ["fallasleep"] = {"mp_sleep", "sleep_loop", "Fall Asleep", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["fightme"] = {"anim@deathmatch_intros@unarmed", "intro_male_unarmed_c", "Fight Me"},
   ["fightme2"] = {"anim@deathmatch_intros@unarmed", "intro_male_unarmed_e", "Fight Me 2"},
   ["finger"] = {"anim@mp_player_intselfiethe_bird", "idle_a", "舉中指", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["finger2"] = {"anim@mp_player_intupperfinger", "idle_a_fp", "雙手舉中指", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["handshake"] = {"mp_ped_interaction", "handshake_guy_a", "握手", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3000
   }},
   ["handshake2"] = {"mp_ped_interaction", "handshake_guy_b", "握手 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3000
   }},
   ["wait"] = {"random@shop_tattoo", "_idle_a", "等候", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitb"] = {"missbigscore2aig_3", "wait_for_van_c", "等候 B", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitc"] = {"amb@world_human_hang_out_street@female_hold_arm@idle_a", "idle_a", "等候 C", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitd"] = {"amb@world_human_hang_out_street@Female_arm_side@idle_a", "idle_a", "等候 D", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waite"] = {"missclothing", "idle_storeclerk", "等候 E", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitf"] = {"timetable@amanda@ig_2", "ig_2_base_amanda", "等候 F", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitg"] = {"rcmnigel1cnmt_1c", "base", "等候 G", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waith"] = {"rcmjosh1", "idle", "等候 H", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waiti"] = {"rcmjosh2", "josh_2_intp1_base", "等候 I", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitj"] = {"timetable@amanda@ig_3", "ig_3_base_tracy", "等候 J", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitk"] = {"misshair_shop@hair_dressers", "keeper_base", "等候 K", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitl"] = {"rcmjosh1", "keeper_base", "等候 L", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["waitm"] = {"rcmnigel1a", "base", "等候 M", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["hiking"] = {"move_m@hiking", "idle", "行山", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["hug"] = {"mp_ped_interaction", "kisses_guy_a", "擁抱"},
   ["hug2"] = {"mp_ped_interaction", "kisses_guy_b", "擁抱 2"},
   ["hug3"] = {"mp_ped_interaction", "hugs_guy_a", "擁抱 3"},
   ["inspect"] = {"random@train_tracks", "idle_e", "檢查"},
   ["jazzhands"] = {"anim@mp_player_intcelebrationfemale@jazz_hands", "jazz_hands", "爵士樂手", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 6000,
   }},
   ["jog2"] = {"amb@world_human_jog_standing@male@idle_a", "idle_a", "緩跑 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["jog3"] = {"amb@world_human_jog_standing@female@idle_a", "idle_a", "緩跑 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["jog4"] = {"amb@world_human_power_walker@female@idle_a", "idle_a", "緩跑 4", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["jog5"] = {"move_m@joy@a", "walk", "緩跑 5", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["jumpingjacks"] = {"timetable@reunited@ig_2", "jimmy_getknocked", "Jumping Jacks", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["kneel2"] = {"rcmextreme3", "idle", "下跪 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["kneel3"] = {"amb@world_human_bum_wash@male@low@idle_a", "idle_a", "下跪 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["knock"] = {"timetable@jimmy@doorknock@", "knockdoor_idle", "Knock", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["knock2"] = {"missheistfbi3b_ig7", "lift_fibagent_loop", "Knock 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["knucklecrunch"] = {"anim@mp_player_intcelebrationfemale@knuckle_crunch", "knuckle_crunch", "啪手指", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["lean2"] = {"amb@world_human_leaning@female@wall@back@hand_up@idle_a", "idle_a", "靠牆企 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lean3"] = {"amb@world_human_leaning@female@wall@back@holding_elbow@idle_a", "idle_a", "靠牆企 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lean4"] = {"amb@world_human_leaning@male@wall@back@foot_up@idle_a", "idle_a", "靠牆企 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lean5"] = {"amb@world_human_leaning@male@wall@back@hands_together@idle_b", "idle_b", "靠牆企 5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["leanflirt"] = {"random@street_race", "_car_a_flirt_girl", "靠 Flirty", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["leanbar2"] = {"amb@prop_human_bum_shopping_cart@male@idle_a", "idle_c", "靠吧檯 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["leanbar3"] = {"anim@amb@nightclub@lazlow@ig1_vip@", "clubvip_base_laz", "靠吧檯 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["leanbar4"] = {"anim@heists@prison_heist", "ped_b_loop_a", "靠吧檯 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["leanhigh"] = {"anim@mp_ferris_wheel", "idle_a_player_one", "靠高牆", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["leanhigh2"] = {"anim@mp_ferris_wheel", "idle_a_player_two", "靠高牆 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["leanside"] = {"timetable@mime@01_gc", "idle_a", "靠埋一邊", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["leanside2"] = {"misscarstealfinale", "packer_idle_1_trevor", "靠埋一邊 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["leanside3"] = {"misscarstealfinalecar_5_ig_1", "waitloop_lamar", "靠埋一邊 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["leanside4"] = {"misscarstealfinalecar_5_ig_1", "waitloop_lamar", "靠埋一邊 4", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["leanside5"] = {"rcmjosh2", "josh_2_intp1_base", "靠埋一邊 5", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["me"] = {"gestures@f@standing@casual", "gesture_me_hard", "我", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 1000
   }},
   ["mechanic"] = {"mini@repair", "fixing_a_ped", "技工", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["mechanic2"] = {"mini@repair", "fixing_a_player", "技工 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["mechanic3"] = {"amb@world_human_vehicle_mechanic@male@base", "base", "技工 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["mechanic4"] = {"anim@amb@clubhouse@tutorial@bkr_tut_ig3@", "machinic_loop_mechandplayer", "技工 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["mechanic5"] = {"amb@prop_human_movie_bulb@idle_a", "idle_b", "技工 5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["medic2"] = {"amb@medic@standing@tendtodead@base", "base", "救護 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["meditate"] = {"rcmcollect_paperleadinout@", "meditiate_idle", "打坐冥想", AnimationOptions = -- CHANGE ME
   {
      EmoteLoop = true,
   }},
   ["meditate2"] = {"rcmepsilonism3", "ep_3_rcm_marnie_meditating", "打坐冥想 2", AnimationOptions = -- CHANGE ME
   {
      EmoteLoop = true,
   }},
   ["meditate3"] = {"rcmepsilonism3", "base_loop", "打坐冥想 3", AnimationOptions = -- CHANGE ME
   {
      EmoteLoop = true,
   }},
   ["metal"] = {"anim@mp_player_intincarrockstd@ps@", "idle_a", "Metal", AnimationOptions = -- CHANGE ME
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["no"] = {"anim@heists@ornate_bank@chat_manager", "fail", "不要", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["no2"] = {"mp_player_int_upper_nod", "mp_player_int_nod_no", "不要 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["nosepick"] = {"anim@mp_player_intcelebrationfemale@nose_pick", "nose_pick", "撩鼻屎", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["noway"] = {"gestures@m@standing@casual", "gesture_no_way", "無可能", AnimationOptions =
   {
      EmoteDuration = 1500,
      EmoteMoving = true,
   }},
   ["ok"] = {"anim@mp_player_intselfiedock", "idle_a", "OK", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["dock"] = {"anim@mp_player_intincardockstd@rds@", "idle_a", "Dock", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["outofbreath"] = {"re@construction", "out_of_breath", "抖唔到氣", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["pickup"] = {"random@domestic", "pickup_low", "拎起"},
   ["push"] = {"missfinale_c2ig_11", "pushcar_offcliff_f", "推", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["push2"] = {"missfinale_c2ig_11", "pushcar_offcliff_m", "推 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["point"] = {"gestures@f@standing@casual", "gesture_point", "手指指", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["pushup"] = {"amb@world_human_push_ups@male@idle_a", "idle_d", "掌上壓", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["countdown"] = {"random@street_race", "grid_girl_race_start", "倒數", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["pointright"] = {"mp_gun_shop_tut", "indicate_right", "手指向右邊", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["salute"] = {"anim@mp_player_intincarsalutestd@ds@", "idle_a", "敬禮", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["salute2"] = {"anim@mp_player_intincarsalutestd@ps@", "idle_a", "敬禮 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["salute3"] = {"anim@mp_player_intuppersalute", "idle_a", "敬禮 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["scared"] = {"random@domestic", "f_distressed_loop", "受驚", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["scared2"] = {"random@homelandsecurity", "knees_loop_girl", "受驚 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["screwyou"] = {"misscommon@response", "screw_you", "吊你啦", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["shakeoff"] = {"move_m@_idles@shake_off", "shakeoff_1", "Shake Off", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3500,
   }},
   ["shot"] = {"random@dealgonewrong", "idle_a", "中槍", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sleep"] = {"timetable@tracy@sleep@", "idle_c", "訓覺", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["shrug"] = {"gestures@f@standing@casual", "gesture_shrug_hard", "無所謂啦", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 1000,
   }},
   ["shrug2"] = {"gestures@m@standing@casual", "gesture_shrug_hard", "無所謂啦 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 1000,
   }},
   ["sit"] = {"anim@amb@business@bgen@bgen_no_work@", "sit_phone_phoneputdown_idle_nowork", "坐地板", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sit2"] = {"rcm_barry3", "barry_3_sit_loop", "坐地板 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sit3"] = {"amb@world_human_picnic@male@idle_a", "idle_a", "坐地板 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sit4"] = {"amb@world_human_picnic@female@idle_a", "idle_a", "坐地板 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sit5"] = {"anim@heists@fleeca_bank@ig_7_jetski_owner", "owner_idle", "坐地板 5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sit6"] = {"timetable@jimmy@mics3_ig_15@", "idle_a_jimmy", "坐地板 6", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sit7"] = {"anim@amb@nightclub@lazlow@lo_alone@", "lowalone_base_laz", "坐地板 7", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sit8"] = {"timetable@jimmy@mics3_ig_15@", "mics3_15_base_jimmy", "坐地板 8", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sit9"] = {"amb@world_human_stupor@male@idle_a", "idle_a", "坐地板 9", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitlow"] = {"anim@veh@lowrider@std@ds@arm@base", "sit_low_lowdoor", "坐低 Lowrider", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitlean"] = {"timetable@tracy@ig_14@", "ig_14_base_tracy", "坐低 靠住", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitsad"] = {"anim@amb@business@bgen@bgen_no_work@", "sit_phone_phoneputdown_sleeping-noworkfemale", "坐低 難過", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitscared"] = {"anim@heists@ornate_bank@hostages@hit", "hit_loop_ped_b", "坐低 受驚", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitscared2"] = {"anim@heists@ornate_bank@hostages@ped_c@", "flinch_loop", "坐低 受驚 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitscared3"] = {"anim@heists@ornate_bank@hostages@ped_e@", "flinch_loop", "坐低 受驚 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitdrunk"] = {"timetable@amanda@drunk@base", "base", "坐低 飲醉", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitchair2"] = {"timetable@ron@ig_5_p3", "ig_5_p3_base", "坐凳 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitchair3"] = {"timetable@reunited@ig_10", "base_amanda", "坐凳 3 (女性)", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitchair4"] = {"timetable@ron@ig_3_couch", "base", "坐凳 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitchair5"] = {"timetable@jimmy@mics3_ig_15@", "mics3_15_base_tracy", "坐凳 翹腳", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitchair6"] = {"timetable@maid@couch@", "base", "坐凳 靠後", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sitchairside"] = {"timetable@ron@ron_ig_2_alt1", "ig_2_alt1_base", "坐凳 側面", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["situp"] = {"amb@world_human_sit_ups@male@idle_a", "idle_a", "Sit Up 仰臥起坐", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["clapangry"] = {"anim@arena@celeb@flat@solo@no_props@", "angry_clap_a_player_a", "拍手 嬲嬲", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["slowclap3"] = {"anim@mp_player_intupperslow_clap", "idle_a", "慢慢拍手 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["clap"] = {"amb@world_human_cheering@male_a", "base", "拍手", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["slowclap"] = {"anim@mp_player_intcelebrationfemale@slow_clap", "slow_clap", "慢慢拍手", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["slowclap2"] = {"anim@mp_player_intcelebrationmale@slow_clap", "slow_clap", "慢慢拍手 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["smell"] = {"move_p_m_two_idles@generic", "fidget_sniff_fingers", "聞一聞", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["stickup"] = {"random@countryside_gang_fight", "biker_02_stickup_loop", "Stick Up", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["stumble"] = {"misscarsteal4@actor", "stumble", "跌跌撞撞", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["stunned"] = {"stungun@standing", "damage", "目瞪口呆", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sunbathe"] = {"amb@world_human_sunbathe@male@back@base", "base", "曬太陽", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["sunbathe2"] = {"amb@world_human_sunbathe@female@back@base", "base", "曬太陽 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["t"] = {"missfam5_yoga", "a2_pose", "T", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["t2"] = {"mp_sleep", "bind_pose_180", "T 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["think5"] = {"mp_cp_welcome_tutthink", "b_think", "思考 5", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 2000,
   }},
   ["think"] = {"misscarsteal4@aliens", "rehearsal_base_idle_director", "思考", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["think3"] = {"timetable@tracy@ig_8@base", "base", "思考 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},

   ["think2"] = {"missheist_jewelleadinout", "jh_int_outro_loop_a", "思考 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["thumbsup3"] = {"anim@mp_player_intincarthumbs_uplow@ds@", "enter", "讚! 3", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3000,
   }},
   ["thumbsup2"] = {"anim@mp_player_intselfiethumbs_up", "idle_a", "讚! 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["thumbsup"] = {"anim@mp_player_intupperthumbs_up", "idle_a", "讚!", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["type"] = {"anim@heists@prison_heiststation@cop_reactions", "cop_b_idle", "打字", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["type2"] = {"anim@heists@prison_heistig1_p1_guard_checks_bus", "loop", "打字 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["type3"] = {"mp_prison_break", "hack_loop", "打字 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["type4"] = {"mp_fbi_heist", "loop", "Type 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["warmth"] = {"amb@world_human_stand_fire@male@idle_a", "idle_a", "取暖", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["wave4"] = {"random@mugging5", "001445_01_gangintimidation_1_female_idle_b", "揮手 4", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3000,
   }},
   ["wave2"] = {"anim@mp_player_intcelebrationfemale@wave", "wave", "揮手 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["wave3"] = {"friends@fra@ig_1", "over_here_idle_a", "揮手 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["wave"] = {"friends@frj@ig_1", "wave_a", "揮手", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["wave5"] = {"friends@frj@ig_1", "wave_b", "揮手 5", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["wave6"] = {"friends@frj@ig_1", "wave_c", "揮手 6", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["wave7"] = {"friends@frj@ig_1", "wave_d", "揮手 7", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["wave8"] = {"friends@frj@ig_1", "wave_e", "揮手 8", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["wave9"] = {"gestures@m@standing@casual", "gesture_hello", "揮手 9", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["whistle"] = {"taxi_hail", "hail_taxi", "吹口哨", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 1300,
   }},
   ["whistle2"] = {"rcmnigel1c", "hailing_whistle_waive_a", "吹口哨 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 2000,
   }},
   ["yeah"] = {"anim@mp_player_intupperair_shagging", "idle_a", "Yeah", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["lift"] = {"random@hitch_lift", "idle_f", "搭順風車", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["lol"] = {"anim@arena@celeb@flat@paired@no_props@", "laugh_a_player_b", "LOL", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["lol2"] = {"anim@arena@celeb@flat@solo@no_props@", "giggle_a_player_b", "LOL 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["statue2"] = {"fra_0_int-1", "cs_lamardavis_dual-1", "雕像 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["statue3"] = {"club_intro2-0", "csb_englishdave_dual-0", "雕像 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["gangsign"] = {"mp_player_int_uppergang_sign_a", "mp_player_int_gang_sign_a", "黑幫手勢", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["gangsign2"] = {"mp_player_int_uppergang_sign_b", "mp_player_int_gang_sign_b", "黑幫手勢 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["passout"] = {"missarmenian2", "drunk_loop", "暈倒", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["passout2"] = {"missarmenian2", "corpse_search_exit_ped", "暈倒 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["passout3"] = {"anim@gangops@morgue@table@", "body_search", "暈倒 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["passout4"] = {"mini@cpr@char_b@cpr_def", "cpr_pumpchest_idle", "暈倒 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["passout5"] = {"random@mugging4", "flee_backward_loop_shopkeeper", "暈倒 5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["petting"] = {"creatures@rottweiler@tricks@", "petting_franklin", "撫摸", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["crawl"] = {"move_injured_ground", "front_loop", "爬行", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["flip2"] = {"anim@arena@celeb@flat@solo@no_props@", "cap_a_player_a", "Flip 2"},
   ["flip"] = {"anim@arena@celeb@flat@solo@no_props@", "flip_a_player_a", "Flip"},
   ["slide"] = {"anim@arena@celeb@flat@solo@no_props@", "slide_a_player_a", "Slide"},
   ["slide2"] = {"anim@arena@celeb@flat@solo@no_props@", "slide_b_player_a", "Slide 2"},
   ["slide3"] = {"anim@arena@celeb@flat@solo@no_props@", "slide_c_player_a", "Slide 3"},
   ["slugger"] = {"anim@arena@celeb@flat@solo@no_props@", "slugger_a_player_a", "Slugger"},
   ["flipoff"] = {"anim@arena@celeb@podium@no_prop@", "flip_off_a_1st", "Flip Off", AnimationOptions =
   {
      EmoteMoving = true,
   }},
   ["flipoff2"] = {"anim@arena@celeb@podium@no_prop@", "flip_off_c_1st", "Flip Off 2", AnimationOptions =
   {
      EmoteMoving = true,
   }},
   ["bow"] = {"anim@arena@celeb@podium@no_prop@", "regal_c_1st", "鞠躬", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["bow2"] = {"anim@arena@celeb@podium@no_prop@", "regal_a_1st", "鞠躬 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["keyfob"] = {"anim@mp_player_intmenu@key_fob@", "fob_click", "用車匙", AnimationOptions =
   {
      EmoteLoop = false,
      EmoteMoving = true,
      EmoteDuration = 1000,
   }},
   ["golfswing"] = {"rcmnigel1d", "swing_a_mark", "打高爾夫球"},
   
   ["eat"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger_fp", "Eat", AnimationOptions =
   {
        Prop = "prop_cs_burger_01",
        PropBone = 18905,
        PropPlacement = {0.12, 0.028, 0.001, 10.0, 175.0},
        EmoteMoving = true,
        EmoteLoop = true,
   }},
   ["reaching"] = {"move_m@intimidation@cop@unarmed", "idle", "Reaching", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["slap"] = {"melee@unarmed@streamed_variations", "plyr_takedown_front_slap", "打人一巴", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
      EmoteDuration = 2000,
   }},
   ["headbutt"] = {"melee@unarmed@streamed_variations", "plyr_takedown_front_headbutt", "頭槌"},
   ["fishdance"] = {"anim@mp_player_intupperfind_the_fish", "idle_a", "Fish Dance", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["peace"] = {"mp_player_int_upperpeace_sign", "mp_player_int_peace_sign", "Peace", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["peace2"] = {"anim@mp_player_intupperpeace", "idle_a", "Peace 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["cpr"] = {"mini@cpr@char_a@cpr_str", "cpr_pumpchest", "CPR", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["cpr2"] = {"mini@cpr@char_a@cpr_str", "cpr_pumpchest", "CPR 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ledge"] = {"missfbi1", "ledge_loop", "Ledge", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["airplane"] = {"missfbi1", "ledge_loop", "飛機", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["peek"] = {"random@paparazzi@peek", "left_peek_a", "Peek", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["cough"] = {"timetable@gardener@smoking_joint", "idle_cough", "Cough", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["stretch"] = {"mini@triathlon", "idle_e", "拉筋", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["stretch2"] = {"mini@triathlon", "idle_f", "拉筋 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["stretch3"] = {"mini@triathlon", "idle_d", "拉筋 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["stretch4"] = {"rcmfanatic1maryann_stretchidle_b", "idle_e", "拉筋 4", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["celebrate"] = {"rcmfanatic1celebrate", "celebrate", "慶祝", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["punching"] = {"rcmextreme2", "loop_punching", "打拳", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["superhero"] = {"rcmbarry", "base", "超級英雄", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["superhero2"] = {"rcmbarry", "base", "超級英雄 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["mindcontrol"] = {"rcmbarry", "mind_control_b_loop", "Mind Control", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["mindcontrol2"] = {"rcmbarry", "bar_1_attack_idle_aln", "Mind Control 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["clown"] = {"rcm_barry2", "clown_idle_0", "小丑", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["clown2"] = {"rcm_barry2", "clown_idle_1", "小丑 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["clown3"] = {"rcm_barry2", "clown_idle_2", "小丑 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["clown4"] = {"rcm_barry2", "clown_idle_3", "小丑 4", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["clown5"] = {"rcm_barry2", "clown_idle_6", "小丑 5", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["tryclothes"] = {"mp_clothing@female@trousers", "try_trousers_neutral_a", "試衫", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["tryclothes2"] = {"mp_clothing@female@shirt", "try_shirt_positive_a", "試衫 2", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["tryclothes3"] = {"mp_clothing@female@shoes", "try_shoes_positive_a", "試衫 3", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["nervous2"] = {"mp_missheist_countrybank@nervous", "nervous_idle", "緊張 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["nervous"] = {"amb@world_human_bum_standing@twitchy@idle_a", "idle_c", "緊張", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["nervous3"] = {"rcmme_tracey1", "nervous_loop", "緊張 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["uncuff"] = {"mp_arresting", "a_uncuff", "解手銬", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["namaste"] = {"timetable@amanda@ig_4", "ig_4_base", "Namaste", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["threaten"] = {"random@atmrobberygen", "b_atm_mugging", "Threaten", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["radio"] = {"random@arrests", "generic_radio_chatter", "用無線電", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["pull"] = {"random@mugging4", "struggle_loop_b_thief", "拉", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["bird"] = {"random@peyote@bird", "wakeup", "Bird"},
   ["chicken"] = {"random@peyote@chicken", "wakeup", "Chicken", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["bark"] = {"random@peyote@dog", "wakeup", "Bark"},
   ["rabbit"] = {"random@peyote@rabbit", "wakeup", "Rabbit"},
   ["spiderman"] = {"missexile3", "ex03_train_roof_idle", "Spider-Man", AnimationOptions =
   {
      EmoteLoop = true,
   }},
   ["boi"] = {"special_ped@jane@monologue_5@monologue_5c", "brotheradrianhasshown_2", "BOI", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 3000,
   }},
   ["adjust"] = {"missmic4", "michael_tux_fidget", "調整衣服", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 4000,
   }},
   ["handsup"] = {"missminuteman_1ig_2", "handsup_base", "舉高雙手", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["handsup2"] = {"anim@mp_player_intuppersurrender", "idle_a_fp", "舉高雙手 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["pee"] = {"misscarsteal2peeing", "peeing_loop", "屙尿", AnimationOptions =
   {
      EmoteStuck = true,
      PtfxAsset = "scr_amb_chop",
      PtfxName = "ent_anim_dog_peeing",
      PtfxNoProp = true,
      PtfxPlacement = {-0.05, 0.3, 0.0, 0.0, 90.0, 90.0, 1.0},
      PtfxInfo = Config.Languages[Config.MenuLanguage]['pee'],
      PtfxWait = 3000,
   }},
   ["valet"] = {"anim@amb@casino@valet_scenario@pose_a@", "base_a_m_y_vinewood_01", "代客泊車", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["valet2"] = {"anim@amb@casino@valet_scenario@pose_b@", "base_a_m_y_vinewood_01", "代客泊車 2", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["valet3"] = {"anim@amb@casino@valet_scenario@pose_d@", "base_a_m_y_vinewood_01", "代客泊車 3", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["hump"] = {"timetable@trevor@skull_loving_bear", "skull_loving_bear", "Hump", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,

   }},
   ["hump2"] = {"timetable@trevor@skull_loving_bear", "skull_loving_bear", "Hump 2 (Bear)", AnimationOptions =
   {
      Prop = 'prop_mr_raspberry_01',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["tighten"] = {"timetable@denice@ig_1", "idle_b", "Tigten (Yoga)", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["fspose"] = {"missfam5_yoga", "c2_pose", "F Sex Pose", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["fspose2"] = {"missfam5_yoga", "c6_pose", "F Sex Pose 2", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["fspose4"] = {"anim@amb@carmeet@checkout_car@", "female_c_idle_d", "F Sex Pose 4", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["showerf"] = {"mp_safehouseshower@female@", "shower_enter_into_idle", "Shower Enter Female", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["showerf2"] = {"mp_safehouseshower@female@", "shower_idle_a", "Shower Female", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["showerf3"] = {"mp_safehouseshower@female@", "shower_idle_b", "Shower Female 2", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["showerm"] = {"mp_safehouseshower@male@", "male_shower_idle_a", "Shower Enter Male", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["showerm2"] = {"mp_safehouseshower@male@", "male_shower_idle_b", "Shower Male 2", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["showerm3"] = {"mp_safehouseshower@male@", "male_shower_idle_c", "Shower Male 3", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["showerm4"] = {"mp_safehouseshower@male@", "male_shower_idle_d", "Shower Male 4", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},
   ["picklock"] = {"missheistfbisetup1", "hassle_intro_loop_f", "Picklock", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["cleanhands"] = {"missheist_agency3aig_23", "urinal_sink_loop", "洗乾淨你隻臭手", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["cleanface"] = {"switch@michael@wash_face", "loop_michael", "洗下你塊面", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true,
   }},
   ["buzz"] = {"anim@apt_trans@buzzer", "buzz_reg", "按門鐘", AnimationOptions =
   {
      EmoteLoop = false,
      EmoteMoving = false,
   }},
   ["piss"] = {"missbigscore1switch_trevor_piss", "piss_loop", "屙尿 (男性)", AnimationOptions =
   {
      EmoteMoving = false,
      EmoteLoop = true,
   }},

   -----------------------------------------------------------------------------------------------------------
   ------ These are Scenarios, some of these dont work on women and some other issues, but still good to have.
   -----------------------------------------------------------------------------------------------------------

   ["atm"] = {"Scenario", "PROP_HUMAN_ATM", "ATM"},
   ["bbq"] = {"MaleScenario", "PROP_HUMAN_BBQ", "BBQ"},
   ["bumbin"] = {"Scenario", "PROP_HUMAN_BUM_BIN", "Bum Bin"},
   ["bumsleep"] = {"Scenario", "WORLD_HUMAN_BUM_SLUMPED", "Bum Sleep"},
   ["cheer"] = {"Scenario", "WORLD_HUMAN_CHEERING", "Cheer"},
   ["chinup"] = {"Scenario", "PROP_HUMAN_MUSCLE_CHIN_UPS", "Chinup"},
   ["clipboard2"] = {"MaleScenario", "WORLD_HUMAN_CLIPBOARD", "板夾寫字板 2"},
   ["cop"] = {"Scenario", "WORLD_HUMAN_COP_IDLES", "警察"},
   ["copbeacon"] = {"MaleScenario", "WORLD_HUMAN_CAR_PARK_ATTENDANT", "警察 指揮交通"},
   ["drilling"] = {"Scenario", "WORLD_HUMAN_CONST_DRILL", "Construction Drilling"},
   ["filmshocking"] = {"Scenario", "WORLD_HUMAN_MOBILE_FILM_SHOCKING", "Film Shocking"},
   ["flex"] = {"Scenario", "WORLD_HUMAN_MUSCLE_FLEX", "炫耀 肌肉"},
   ["guard"] = {"Scenario", "WORLD_HUMAN_GUARD_STAND", "守衛"},
   ["garden"] = {"Scenario", "WORLD_HUMAN_GARDENER_PLANT", "園藝"},
   ["hammer"] = {"Scenario", "WORLD_HUMAN_HAMMERING", "錘仔揼牆"},
   ["hangout"] = {"Scenario", "WORLD_HUMAN_HANG_OUT_STREET", "Hangout"},
   ["impatient"] = {"Scenario", "WORLD_HUMAN_STAND_IMPATIENT", "唔耐煩"},
   ["janitor"] = {"Scenario", "WORLD_HUMAN_JANITOR", "掃地"},
   ["jog"] = {"Scenario", "WORLD_HUMAN_JOG_STANDING", "緩跑"},
   ["kneel"] = {"Scenario", "CODE_HUMAN_MEDIC_KNEEL", "下跪"},
   ["lean"] = {"Scenario", "WORLD_HUMAN_LEANING", "靠牆企"},
   ["leanbar"] = {"Scenario", "PROP_HUMAN_BUM_SHOPPING_CART", "靠吧檯"},
   ["lookout"] = {"Scenario", "CODE_HUMAN_CROSS_ROAD_WAIT", "Lookout"},
   ["maid"] = {"Scenario", "WORLD_HUMAN_MAID_CLEAN", "Maid"},
   ["medic"] = {"Scenario", "CODE_HUMAN_MEDIC_TEND_TO_DEAD", "救護"},
   ["musician"] = {"MaleScenario", "WORLD_HUMAN_MUSICIAN", "彈結他"}, -- Ambient Music Doesn't Seem To Work For Female, Hence It's Male Only
   ["notepad2"] = {"Scenario", "CODE_HUMAN_MEDIC_TIME_OF_DEATH", "記事本 2"},
   ["parkingmeter"] = {"Scenario", "PROP_HUMAN_PARKING_METER", "咪錶"},
   ["party"] = {"Scenario", "WORLD_HUMAN_PARTYING", "派對"},
   ["texting"] = {"Scenario", "WORLD_HUMAN_STAND_MOBILE", "手機send message"},
   ["prosthigh"] = {"Scenario", "WORLD_HUMAN_PROSTITUTE_HIGH_CLASS", "妓女 高"},
   ["prostlow"] = {"Scenario", "WORLD_HUMAN_PROSTITUTE_LOW_CLASS", "妓女 低"},
   ["puddle"] = {"Scenario", "WORLD_HUMAN_BUM_WASH", "Puddle"},
   ["record"] = {"Scenario", "WORLD_HUMAN_MOBILE_FILM_SHOCKING", "Record"},

   -- Sitchair is a litte special, since you want the player to be seated correctly.
   -- So we set it as "ScenarioObject" and do TaskStartScenarioAtPosition() instead of "AtPlace"

   ["sitchair"] = {"ScenarioObject", "PROP_HUMAN_SEAT_CHAIR_MP_PLAYER", "坐凳"},
   ["smoke"] = {"Scenario", "WORLD_HUMAN_SMOKING", "食煙"},
   ["smokeweed"] = {"MaleScenario", "WORLD_HUMAN_DRUG_DEALER", "Smoke Weed (男)"}, -- Male
   ["smokepot"] = {"Scenario", "WORLD_HUMAN_SMOKING_POT", "Smoke Weed (女)"}, -- Female
   ["statue"] = {"Scenario", "WORLD_HUMAN_HUMAN_STATUE", "雕像"},
   ["sunbathe3"] = {"Scenario", "WORLD_HUMAN_SUNBATHE", "曬太陽 3"},
   ["sunbatheback"] = {"Scenario", "WORLD_HUMAN_SUNBATHE_BACK", "曬太陽 背面"},
   ["weld"] = {"Scenario", "WORLD_HUMAN_WELDING", "焊接"},
   ["windowshop"] = {"Scenario", "WORLD_HUMAN_WINDOW_SHOP_BROWSE", "齋睇唔買"},
   ["yoga"] = {"Scenario", "WORLD_HUMAN_YOGA", "Yoga"},

   -- CASINO DLC EMOTES (Requires gamebuild 2060 or higher)
   ["karate"] = {"anim@mp_player_intcelebrationfemale@karate_chops", "karate_chops", "空手道"},
   ["karate2"] = {"anim@mp_player_intcelebrationmale@karate_chops", "karate_chops", "空手道 2"},
   ["cutthroat"] = {"anim@mp_player_intcelebrationmale@cut_throat", "cut_throat", "恐嚇 (割喉)"},
   ["cutthroat2"] = {"anim@mp_player_intcelebrationfemale@cut_throat", "cut_throat", "恐嚇 (割喉) 2"},
   ["mindblown"] = {"anim@mp_player_intcelebrationmale@mind_blown", "mind_blown", "Mind Blown", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 4000
   }},
   ["mindblown2"] = {"anim@mp_player_intcelebrationfemale@mind_blown", "mind_blown", "Mind Blown 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 4000
   }},
   ["boxing"] = {"anim@mp_player_intcelebrationmale@shadow_boxing", "shadow_boxing", "Boxing", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 4000
   }},
   ["boxing2"] = {"anim@mp_player_intcelebrationfemale@shadow_boxing", "shadow_boxing", "Boxing 2", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 4000
   }},
   ["stink"] = {"anim@mp_player_intcelebrationfemale@stinker", "stinker", "好臭", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["think4"] = {"anim@amb@casino@hangout@ped_male@stand@02b@idles", "idle_a", "思考 4", AnimationOptions =
   {
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["adjusttie"] = {"clothingtie", "try_tie_positive_a", "調整領帶", AnimationOptions =
   {
      EmoteMoving = true,
      EmoteDuration = 5000
   }},
}

DP.PropEmotes = {
   ["megaphone"] = {"amb@world_human_mobile_film_shocking@female@base", "base", "大聲公", AnimationOptions =
   {
       Prop = 'prop_megaphone_01',
       PropBone = 28422,
       PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 80.0},
       EmoteLoop = true,
       EmoteMoving = true,
   }},
   --Jim-VanillaUnicorn
	["whiskeyb"] = {"mp_player_intdrink", "loop_bottle", "(Don't Use) Whiskey Bottle", AnimationOptions =
	{    Prop = "prop_cs_whiskey_bottle", PropBone = 60309, PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0},
		EmoteMoving = true, EmoteLoop = true }},
	["rumb"] = {"mp_player_intdrink", "loop_bottle", "(Don't Use) Rum Bottle", AnimationOptions =
	{    Prop = "prop_rum_bottle", PropBone = 18905, PropPlacement = {0.03, -0.18, 0.10, 240.0, -60.0},
		EmoteMoving = true, EmoteLoop = true }},
	["icream"] = {"mp_player_intdrink", "loop_bottle", "Irish Cream Bottle", AnimationOptions =
	{    Prop = "prop_bottle_brandy", PropBone = 18905, PropPlacement = {0.00, -0.26, 0.10, 240.0, -60.0},
		EmoteMoving = true, EmoteLoop = true }},
	["ginb"] =  {"mp_player_intdrink", "loop_bottle", "(Don't Use) Gin Bottle", AnimationOptions =
	{    Prop = "prop_tequila_bottle", PropBone = 18905, PropPlacement = {0.00, -0.26, 0.10, 240.0, -60.0},
		EmoteMoving = true, EmoteLoop = true }},
	["vodkab"] = {"mp_player_intdrink", "loop_bottle", "(Don't Use) Vodka Bottle", AnimationOptions =
	{   Prop = 'prop_vodka_bottle', PropBone = 18905, PropPlacement = {0.00, -0.26, 0.10, 240.0, -60.0},
		EmoteMoving = true, EmoteLoop = true }},

   ["crisps"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "Chrisps", AnimationOptions =
   {   Prop = 'v_ret_ml_chips2', PropBone = 28422, PropPlacement = {0.01, -0.05, -0.1, 0.0, 0.0, 90.0},
       EmoteLoop = true, EmoteMoving = true, }},
   ["beer1"] = {"mp_player_intdrink", "loop_bottle", "Dusche", AnimationOptions =
   {    Prop = "prop_beerdusche", PropBone = 18905, PropPlacement = {0.04, -0.14, 0.10, 240.0, -60.0},
        EmoteMoving = true, EmoteLoop = true, }},
   ["beer2"] = {"mp_player_intdrink", "loop_bottle", "Logger", AnimationOptions =
   {    Prop = "prop_beer_logopen", PropBone = 18905, PropPlacement = {0.03, -0.18, 0.10, 240.0, -60.0},
        EmoteMoving = true, EmoteLoop = true, }},
   ["beer3"] = {"mp_player_intdrink", "loop_bottle", "AM Beer", AnimationOptions =
   {    Prop = "prop_beer_amopen", PropBone = 18905, PropPlacement = {0.03, -0.18, 0.10, 240.0, -60.0},
        EmoteMoving = true, EmoteLoop = true, }},
   ["beer4"] = {"mp_player_intdrink", "loop_bottle", "Pisswasser1", AnimationOptions =
   {    Prop = "prop_beer_pissh", PropBone = 18905, PropPlacement = {0.03, -0.18, 0.10, 240.0, -60.0},
        EmoteMoving = true, EmoteLoop = true, }},
   ["beer5"] = {"mp_player_intdrink", "loop_bottle", "Pisswasser2", AnimationOptions =
   {    Prop = "prop_amb_beer_bottle", PropBone = 18905, PropPlacement = {0.12, 0.008, 0.03, 240.0, -60.0},
        EmoteMoving = true, EmoteLoop = true, }},
   ["beer6"] = {"mp_player_intdrink", "loop_bottle", "Pisswasser3", AnimationOptions =
   {    Prop = "prop_cs_beer_bot_02", PropBone = 18905, PropPlacement = {0.12, 0.008, 0.03, 240.0, -60.0},
        EmoteMoving = true, EmoteLoop = true, }},
   ["ecola"] = {"mp_player_intdrink", "loop_bottle", "E-cola", AnimationOptions =
   {    Prop = "prop_ecola_can", PropBone = 18905, PropPlacement = {0.12, 0.008, 0.03, 240.0, -60.0},
        EmoteMoving = true, EmoteLoop = true, }},
   ["sprunk"] = {"mp_player_intdrink", "loop_bottle", "Sprunk", AnimationOptions =
   {    Prop = "v_res_tt_can03", PropBone = 18905, PropPlacement = {0.12, 0.008, 0.03, 240.0, -60.0},
        EmoteMoving = true, EmoteLoop = true, }},
        
	--Jim-CatCafe
	["uwu1"] = { "amb@world_human_drinking@coffee@male@idle_a", "idle_c", "", AnimationOptions =
	{    Prop = 'uwu_sml_drink', PropBone = 28422, PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
		EmoteLoop = true, EmoteMoving = true, }},
	["uwu2"] = { "mp_player_inteat@burger", "mp_player_int_eat_burger", "", AnimationOptions =
	{    Prop = 'uwu_pastry', PropBone = 18905, PropPlacement = {0.15, 0.06, -0.02, -50.0, 16.0, 60.0},
		EmoteMoving = true, }},
	["uwu3"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger", "", AnimationOptions =
	{    Prop = 'uwu_sushi', PropBone = 18905, PropPlacement = {0.13, 0.05, 0.02, -50.0, 16.0, 60.0},
		EmoteMoving = true, }},
	["uwu4"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger_fp", "", AnimationOptions =
	{    Prop = 'uwu_eggroll', PropBone = 18905, PropPlacement = {0.13, 0.05, 0.02, -50.0, 50.0, 0.0},
		EmoteMoving = true, }},
	["uwu5"] = {"anim@scripted@island@special_peds@pavel@hs4_pavel_ig5_caviar_p1", "base_idle", "", AnimationOptions =
	{    Prop = "uwu_salad_bowl", PropBone = 60309, PropPlacement = {-0.015, 0.03, 0.01, 0.0, 0.0, 0.0},
		SecondProp = 'uwu_salad_spoon', SecondPropBone = 28422, SecondPropPlacement = {0.0, 0.0 ,0.0, 0.0, 0.0, 0.0},
		EmoteLoop = true, EmoteMoving = true, }},
	["uwu6"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "Iced Latte", AnimationOptions =
	{    Prop = 'uwu_cup_straw',PropBone = 28422,PropPlacement = {0.0, 0.0, -0.03, 0.0, 0.0, 270.0},
		EmoteLoop = true,EmoteMoving = true,}},
	["uwu7"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "", AnimationOptions =
	{    Prop = 'apa_prop_cs_plastic_cup_01',PropBone = 28422,PropPlacement = {0.0, 0.0, -0.06, 0.0, 0.0, 90.0},
		EmoteLoop = true, EmoteMoving = true, }},
	["uwu8"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "", AnimationOptions =
	{    Prop = 'uwu_miso', PropBone = 28422, PropPlacement = {0.025, 0.0, -0.02, 0.0, 10.0, 0.0},
		EmoteLoop = true, EmoteMoving = true, }},
	["uwu9"] = {"anim@scripted@island@special_peds@pavel@hs4_pavel_ig5_caviar_p1", "base_idle", "", AnimationOptions =
	{    Prop = "prop_cs_bowl_01b", PropBone = 60309, PropPlacement = {0.0, 0.03, 0.01, 0.0, 0.0, 0.0}, SecondProp = 'uwu_salad_spoon',
		SecondPropBone = 28422,    SecondPropPlacement = {0.0,0.0,0.0,0.0,0.0,0.0},
		EmoteLoop = true, EmoteMoving = true, }},
	["uwu10"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "", AnimationOptions =
	{    Prop = 'uwu_lrg_drink', PropBone = 28422, PropPlacement = {0.02, 0.0, -0.06, 0.0, 0.0, 90.0},
		EmoteLoop = true, EmoteMoving = true, }},        
	["uwu11"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "", AnimationOptions =
	{    Prop = 'uwu_mug', PropBone = 28422, PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 130.0},
		EmoteLoop = true, EmoteMoving = true, }}, 
	["uwu12"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger", "", AnimationOptions =
	{    Prop = 'uwu_cookie', PropBone = 18905, PropPlacement = {0.16, 0.08, -0.01, -225.0, 20.0, 60.0},
		EmoteMoving = true, }},
   ["uwu13"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger", "", AnimationOptions =
	{ Prop = 'uwu_gdasik', PropBone = 18905, PropPlacement = {0.16, 0.08, 0.02, -225.0, 20.0, 60.0},
		EmoteMoving = true, }},
   ["umbrella"] = {"amb@world_human_drinking@coffee@male@base", "base", "拎遮", AnimationOptions =
   {
      Prop = "p_amb_brolly_01",
      PropBone = 57005,
      PropPlacement = {0.15, 0.005, 0.0, 87.0, -20.0, 180.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ['umbrella2'] = {'rcmnigel1d', 'base_club_shoulder', '拎遮 2', AnimationOptions =
   {
      Prop = 'p_amb_brolly_01',
      PropBone = 28422,
      PropPlacement = {0.0700, 0.0100, 0.1100, 2.3402393, -150.9605721, 57.3374916},
      EmoteLoop = true,
      EmoteMoving = true,
   }},

   -----------------------------------------------------------------------------------------------------
   ------ This is an example of an emote with 2 props, pretty simple! ----------------------------------
   -----------------------------------------------------------------------------------------------------

   ["notepad"] = {"missheistdockssetup1clipboard@base", "base", "記事本", AnimationOptions =
   {
      Prop = 'prop_notepad_01',
      PropBone = 18905,
      PropPlacement = {0.1, 0.02, 0.05, 10.0, 0.0, 0.0},
      SecondProp = 'prop_pencil_01',
      SecondPropBone = 58866,
      SecondPropPlacement = {0.11, -0.02, 0.001, -120.0, 0.0, 0.0},
      -- EmoteLoop is used for emotes that should loop, its as simple as that.
      -- Then EmoteMoving is used for emotes that should only play on the upperbody.
      -- The code then checks both values and sets the MovementType to the correct one
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["box"] = {"anim@heists@box_carry@", "idle", "紙皮箱", AnimationOptions =
   {
      Prop = "hei_prop_heist_box",
      PropBone = 60309,
      PropPlacement = {0.025, 0.08, 0.255, -145.0, 290.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["rose"] = {"anim@heists@humane_labs@finale@keycards", "ped_a_enter_loop", "玫瑰", AnimationOptions =
   {
      Prop = "prop_single_rose",
      PropBone = 18905,
      PropPlacement = {0.13, 0.15, 0.0, -100.0, 0.0, -20.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["smoke2"] = {"amb@world_human_aa_smoke@male@idle_a", "idle_c", "食煙 2", AnimationOptions =
   {
      Prop = 'prop_cs_ciggy_01',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["smoke3"] = {"amb@world_human_aa_smoke@male@idle_a", "idle_b", "食煙 3", AnimationOptions =
   {
      Prop = 'prop_cs_ciggy_01',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["smoke4"] = {"amb@world_human_smoking@female@idle_a", "idle_b", "食煙 4", AnimationOptions =
   {
      Prop = 'prop_cs_ciggy_01',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["bong"] = {"anim@safehouse@bong", "bong_stage3", "Bong", AnimationOptions =
   {
      Prop = 'hei_heist_sh_bong_01',
      PropBone = 18905,
      PropPlacement = {0.10,-0.25,0.0,95.0,190.0,180.0},
   }},
   ["fishing1"] = {"amb@world_human_stand_fishing@idle_a", "idle_a", "釣魚 1", AnimationOptions =
   {
      Prop = 'prop_fishing_rod_01',
      PropBone = 60309,
      PropPlacement = {0.0,0.0,0.0,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["fishing2"] = {"amb@world_human_stand_fishing@idle_a", "idle_b", "釣魚 2", AnimationOptions =
   {
      Prop = 'prop_fishing_rod_01',
      PropBone = 60309,
      PropPlacement = {0.0,0.0,0.0,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["fishing3"] = {"amb@world_human_stand_fishing@idle_a", "idle_c", "釣魚 3", AnimationOptions =
   {
      Prop = 'prop_fishing_rod_01',
      PropBone = 60309,
      PropPlacement = {0.0,0.0,0.0,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["suitcase"] = {"move_weapon@jerrycan@generic", "idle", "手提箱", AnimationOptions =
   {
      Prop = "prop_ld_suitcase_01",
      PropBone = 57005,
      PropPlacement = {0.35, 0.0, 0.0, 0.0, 266.0, 90.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["suitcase2"] = {"move_weapon@jerrycan@generic", "idle", "手提箱 2", AnimationOptions =
   {
      Prop = "prop_security_case_01",
      PropBone = 57005,
      PropPlacement = {0.13, 0.0, -0.01, 0.0, 280.0, 90.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["boombox"] = {"move_weapon@jerrycan@generic", "idle", "大喇叭", AnimationOptions =
   {
      Prop = "prop_boombox_01",
      PropBone = 57005,
      PropPlacement = {0.27, 0.0, 0.0, 0.0, 263.0, 58.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["toolbox"] = {"move_weapon@jerrycan@generic", "idle", "工具箱", AnimationOptions =
   {
      Prop = "prop_tool_box_04",
      PropBone = 28422,
      PropPlacement = {0.3960,0.0410,-0.0030, -90.00, 0.0, 90.00},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["toolbox2"] = {"move_weapon@jerrycan@generic", "idle", "工具箱 2", AnimationOptions =
   {
      Prop = "imp_prop_tool_box_01a",
      PropBone = 28422,
      PropPlacement = {0.3700,0.0200, 0.0, 90.00, 0.0, -90.00},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["gbag"] = {"missfbi4prepp1", "_idle_garbage_man", "垃圾袋", AnimationOptions =
   {
      Prop = "prop_cs_street_binbag_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0400, -0.0200, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beerbox"] = {"move_weapon@jerrycan@generic", "idle", "啤酒箱 1", AnimationOptions =
   {
      Prop = "v_ret_ml_beerdus",
      PropBone = 57005,
      PropPlacement = {0.22, 0.0, 0.0, 0.0, 266.0, 48.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beerbox2"] = {"move_weapon@jerrycan@generic", "idle", "啤酒箱 2", AnimationOptions =
   {
      Prop = "v_ret_ml_beeram",
      PropBone = 57005,
      PropPlacement = {0.22, 0.0, 0.0, 0.0, 266.0, 48.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beerbox3"] = {"move_weapon@jerrycan@generic", "idle", "啤酒箱 3", AnimationOptions =
   {
      Prop = "v_ret_ml_beerpride",
      PropBone = 57005,
      PropPlacement = {0.22, 0.0, 0.0, 0.0, 266.0, 48.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beerbox4"] = {"move_weapon@jerrycan@generic", "idle", "啤酒箱 4", AnimationOptions =
   {
      Prop = "v_ret_ml_beerbar",
      PropBone = 57005,
      PropPlacement = {0.22, 0.0, 0.0, 0.0, 266.0, 60.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["mugshot"] = {"mp_character_creation@customise@male_a", "loop", "疑犯大頭相", AnimationOptions =
   {
      Prop = 'prop_police_id_board',
      PropBone = 58868,
      PropPlacement = {0.12, 0.24, 0.0, 5.0, 0.0, 70.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["coffee"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "飲咖啡", AnimationOptions =
   {
      Prop = 'p_amb_coffeecup_01',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["whiskey"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "飲威士忌", AnimationOptions =
   {
      Prop = 'prop_drink_whisky',
      PropBone = 28422,
      PropPlacement = {0.01, -0.01, -0.06, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["whiskeyb"] = {"amb@world_human_drinking@beer@male@idle_a", "idle_a", "威士忌酒瓶", AnimationOptions =
   {
      Prop = 'ba_prop_battle_whiskey_bottle_2_s',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.05, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},

   ["beer"] = {"amb@world_human_drinking@beer@male@idle_a", "idle_c", "飲啤酒", AnimationOptions =
   {
      Prop = 'prop_amb_beer_bottle',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.06, 0.0, 15.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beer2"] = {"amb@world_human_drinking@beer@male@idle_a", "idle_a", "飲啤酒 2", AnimationOptions =
   {
      Prop = 'ba_prop_battle_whiskey_bottle_2_s',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.05, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beer3"] = {"amb@world_human_drinking@beer@male@idle_a", "idle_c", "飲啤酒 3", AnimationOptions =
   {
      Prop = 'prop_amb_beer_bottle',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.06, 0.0, 15.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["beer4"] = {"amb@world_human_drinking@beer@male@idle_a", "idle_a", "飲啤酒 4", AnimationOptions =
   {
      Prop = 'ba_prop_battle_whiskey_bottle_2_s',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.05, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["beerf"] = {"amb@world_human_drinking@beer@female@idle_a", "idle_a", "飲啤酒 女性", AnimationOptions =
   {
      Prop = 'prop_amb_beer_bottle',
      PropBone = 28422,
      PropPlacement = {0.0, -0.0, 0.05, 15.0, 15.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beerf2"] = {"amb@world_human_drinking@beer@female@idle_a", "idle_e", "飲啤酒 女性 2", AnimationOptions =
   {
      Prop = 'prop_wine_rose',
      PropBone = 28422,
      PropPlacement = {-0.0, 0.04, -0.19, 10.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
      ---       PropPlacement = {-0.0, 0.03, -0.20, 5.0, 0.0, 0.0},
      ---                         F&B   L&R   U&D  R.F&B
   }},
   ["beerf3"] = {"amb@world_human_drinking@beer@female@idle_a", "idle_a", "飲啤酒 女性 3", AnimationOptions =
   {
      Prop = 'prop_amb_beer_bottle',
      PropBone = 28422,
      PropPlacement = {0.0, -0.0, 0.05, 15.0, 15.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["beerf4"] = {"amb@world_human_drinking@beer@female@idle_a", "idle_e", "飲啤酒 女性 4", AnimationOptions =
   {
      Prop = 'prop_wine_rose',
      PropBone = 28422,
      PropPlacement = {-0.0, 0.04, -0.19, 10.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = false,
      ---       PropPlacement = {-0.0, 0.03, -0.20, 5.0, 0.0, 0.0},
      ---                         F&B   L&R   U&D  R.F&B
   }},
   ["cup"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "杯", AnimationOptions =
   {
      Prop = 'prop_plastic_cup_02',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["donut"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger", "食Donut", AnimationOptions =
   {
      Prop = 'prop_amb_donut',
      PropBone = 18905,
      PropPlacement = {0.13, 0.05, 0.02, -50.0, 16.0, 60.0},
      EmoteMoving = true,
   }},
   ["burger"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger", "食漢堡", AnimationOptions =
   {
      Prop = 'prop_cs_burger_01',
      PropBone = 18905,
      PropPlacement = {0.13, 0.05, 0.02, -50.0, 16.0, 60.0},
      EmoteMoving = true,
   }},
   ["sandwich"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger", "食三明治", AnimationOptions =
   {
      Prop = 'prop_sandwich_01',
      PropBone = 18905,
      PropPlacement = {0.13, 0.05, 0.02, -50.0, 16.0, 60.0},
      EmoteMoving = true,
   }},
   ["soda"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "飲汽水", AnimationOptions =
   {
      Prop = 'prop_ecola_can',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 130.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["water"] = {"amb@world_human_drinking@coffee@male@idle_a", "idle_c", "飲水", AnimationOptions =
   {
      Prop = 'ba_prop_club_water_bottle',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, -0.090, 0.0, 0.0, 130.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["egobar"] = {"mp_player_inteat@burger", "mp_player_int_eat_burger", "食能量棒", AnimationOptions =
   {
      Prop = 'prop_choc_ego',
      PropBone = 60309,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteMoving = true,
   }},
   ["candy"] = {"mp_player_inteat@pnq", "loop", "食糖", AnimationOptions =
   {
      Prop = 'prop_candy_pqs',
      PropBone = 60309,
      PropPlacement = {-0.0300, 0.0180, 0.0, 180.0, 180.0, -88.099},
      EmoteMoving = true,
   }},
   ["wine"] = {"anim@heists@humane_labs@finale@keycards", "ped_a_enter_loop", "飲紅酒", AnimationOptions =
   {
      Prop = 'prop_drink_redwine',
      PropBone = 18905,
      PropPlacement = {0.10, -0.03, 0.03, -100.0, 0.0, -10.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["flute"] = {"anim@heists@humane_labs@finale@keycards", "ped_a_enter_loop", "香檳杯", AnimationOptions =
   {
      Prop = 'prop_champ_flute',
      PropBone = 18905,
      PropPlacement = {0.10, -0.03, 0.03, -100.0, 0.0, -10.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["champagne"] = {"anim@heists@humane_labs@finale@keycards", "ped_a_enter_loop", "飲香檳", AnimationOptions =
   {
      Prop = 'prop_drink_champ',
      PropBone = 18905,
      PropPlacement = {0.10, -0.03, 0.03, -100.0, 0.0, -10.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["cigar"] = {"amb@world_human_smoking@male@male_a@enter", "enter", "雪茄", AnimationOptions =
   {
      Prop = 'prop_cigar_02',
      PropBone = 47419,
      PropPlacement = {0.010, 0.0, 0.0, 50.0, 0.0, -80.0},
      EmoteMoving = true,
      EmoteDuration = 2600
   }},
   ["cigar2"] = {"amb@world_human_smoking@male@male_a@enter", "enter", "雪茄 2", AnimationOptions =
   {
      Prop = 'prop_cigar_01',
      PropBone = 47419,
      PropPlacement = {0.010, 0.0, 0.0, 50.0, 0.0, -80.0},
      EmoteMoving = true,
      EmoteDuration = 2600
   }},
   ["guitar"] = {"amb@world_human_musician@guitar@male@idle_a", "idle_b", "結他", AnimationOptions =
   {
      Prop = 'prop_acc_guitar_01',
      PropBone = 24818,
      PropPlacement = {-0.1, 0.31, 0.1, 0.0, 20.0, 150.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["guitar2"] = {"switch@trevor@guitar_beatdown", "001370_02_trvs_8_guitar_beatdown_idle_busker", "結他 2", AnimationOptions =
   {
      Prop = 'prop_acc_guitar_01',
      PropBone = 24818,
      PropPlacement = {-0.05, 0.31, 0.1, 0.0, 20.0, 150.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["guitarelectric"] = {"amb@world_human_musician@guitar@male@idle_a", "idle_b", "電子結他", AnimationOptions =
   {
      Prop = 'prop_el_guitar_01',
      PropBone = 24818,
      PropPlacement = {-0.1, 0.31, 0.1, 0.0, 20.0, 150.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["guitarelectric2"] = {"amb@world_human_musician@guitar@male@idle_a", "idle_b", "電子結他 2", AnimationOptions =
   {
      Prop = 'prop_el_guitar_03',
      PropBone = 24818,
      PropPlacement = {-0.1, 0.31, 0.1, 0.0, 20.0, 150.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["book"] = {"cellphone@", "cellphone_text_read_base", "睇書", AnimationOptions =
   {
      Prop = 'prop_novel_01',
      PropBone = 6286,
      PropPlacement = {0.15, 0.03, -0.065, 0.0, 180.0, 90.0}, -- This positioning isnt too great, was to much of a hassle
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["bouquet"] = {"impexp_int-0", "mp_m_waremech_01_dual-0", "一束花", AnimationOptions =
   {
      Prop = 'prop_snow_flower_02',
      PropBone = 24817,
      PropPlacement = {-0.29, 0.40, -0.02, -90.0, -90.0, 0.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["teddy"] = {"impexp_int-0", "mp_m_waremech_01_dual-0", "泰迪熊", AnimationOptions =
   {
      Prop = 'v_ilev_mr_rasberryclean',
      PropBone = 24817,
      PropPlacement = {-0.20, 0.46, -0.016, -180.0, -90.0, 0.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["backpack"] = {"move_p_m_zero_rucksack", "nill", "背包", AnimationOptions =
   {
      Prop = 'p_michael_backpack_s',
      PropBone = 24818,
      PropPlacement = {0.07, -0.11, -0.05, 0.0, 90.0, 175.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["clipboard"] = {"missfam4", "base", "板夾寫字板", AnimationOptions =
   {
      Prop = 'p_amb_clipboard_01',
      PropBone = 36029,
      PropPlacement = {0.16, 0.08, 0.1, -130.0, -50.0, 0.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["map"] = {"amb@world_human_tourist_map@male@base", "base", "睇地圖", AnimationOptions =
   {
      Prop = 'prop_tourist_map_01',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteMoving = true,
      EmoteLoop = true
   }},
   ["map2"] = {"amb@code_human_in_bus_passenger_idles@female@tablet@idle_a", "idle_a", "睇地圖 2", AnimationOptions =
   {
      Prop = "prop_tourist_map_01",
      PropBone = 28422,
      PropPlacement = {-0.05, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beg"] = {"amb@world_human_bum_freeway@male@base", "base", "行乞", AnimationOptions =
   {
      Prop = 'prop_beggers_sign_03',
      PropBone = 58868,
      PropPlacement = {0.19, 0.18, 0.0, 5.0, 0.0, 40.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["makeitrain"] = {"anim@mp_player_intupperraining_cash", "idle_a", "Make It Rain (灑錢)", AnimationOptions =
   {
      Prop = 'prop_anim_cash_pile_01',
      PropBone = 60309,
      PropPlacement = {0.0, 0.0, 0.0, 180.0, 0.0, 70.0},
      EmoteMoving = true,
      EmoteLoop = true,
      PtfxAsset = "scr_xs_celebration",
      PtfxName = "scr_xs_money_rain",
      PtfxPlacement = {0.0, 0.0, -0.09, -80.0, 0.0, 0.0, 1.0},
      PtfxInfo = Config.Languages[Config.MenuLanguage]['makeitrain'],
      PtfxWait = 500,
   }},
   ["camera"] = {"amb@world_human_paparazzi@male@base", "base", "影相", AnimationOptions =
   {
      Prop = 'prop_pap_camera_01',
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
      PtfxAsset = "scr_bike_business",
      PtfxName = "scr_bike_cfid_camera_flash",
      PtfxPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0},
      PtfxInfo = Config.Languages[Config.MenuLanguage]['camera'],
      PtfxWait = 200,
   }},
   ["champagnespray"] = {"anim@mp_player_intupperspray_champagne", "idle_a", "噴香檳", AnimationOptions =
   {
      Prop = 'ba_prop_battle_champ_open',
      PropBone = 28422,
      PropPlacement = {0.0,0.0,0.0,0.0,0.0,0.0},
      EmoteMoving = true,
      EmoteLoop = true,
      PtfxAsset = "scr_ba_club",
      PtfxName = "scr_ba_club_champagne_spray",
      PtfxPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      PtfxInfo = Config.Languages[Config.MenuLanguage]['spraychamp'],
      PtfxWait = 500,
   }},
   ["joint"] = {"amb@world_human_smoking@male@male_a@enter", "enter", "點起左枝Joint", AnimationOptions =
   {
      Prop = 'p_cs_joint_02',
      PropBone = 47419,
      PropPlacement = {0.015, -0.009, 0.003, 55.0, 0.0, 110.0},
      EmoteMoving = true,
      EmoteDuration = 2600
   }},
   ["cig"] = {"amb@world_human_smoking@male@male_a@enter", "enter", "食煙", AnimationOptions =
   {
      Prop = 'prop_amb_ciggy_01',
      PropBone = 47419,
      PropPlacement = {0.015, -0.009, 0.003, 55.0, 0.0, 110.0},
      EmoteMoving = true,
      EmoteDuration = 2600
   }},
   ["brief"]  = {"move_weapon@jerrycan@generic", "idle", "公事包", AnimationOptions =
   {
      Prop = "prop_ld_case_01",
      PropBone = 57005,
      PropPlacement = {0.12, 0.0, 0.0, 0.0, 255.0, 80.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tablet"] = {"amb@world_human_tourist_map@male@base", "base", "平板電腦", AnimationOptions =
   {
      Prop = "prop_cs_tablet",
      PropBone = 28422,
      PropPlacement = {0.0, -0.03, 0.0, 20.0, -90.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tablet2"] = {"amb@code_human_in_bus_passenger_idles@female@tablet@idle_a", "idle_a", "平板電腦 2", AnimationOptions =
   {
      Prop = "prop_cs_tablet",
      PropBone = 28422,
      PropPlacement = {-0.05, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["phonecall"] = {"cellphone@", "cellphone_call_listen_base", "打電話", AnimationOptions =
   {
      Prop = "prop_phone_ing",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["phonecall2"] = {"random@kidnap_girl", "ig_1_girl_on_phone_loop", "打電話 2", AnimationOptions =
   {
      Prop = "prop_phone_ing",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["phone"] = {"cellphone@", "cellphone_text_read_base", "手機", AnimationOptions =
   {
      Prop = "prop_phone_cs_frank",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["clean"] = {"timetable@floyd@clean_kitchen@base", "base", "清潔", AnimationOptions =
   {
      Prop = "prop_sponge_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, -0.01, 90.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["clean2"] = {"amb@world_human_maid_clean@", "base", "清潔 2", AnimationOptions =
   {
      Prop = "prop_sponge_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, -0.01, 90.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["protest"] = {"rcmnigel1d", "base_club_shoulder", "示威", AnimationOptions =
   {
      Prop = "prop_cs_protest_sign_01",
      PropBone = 57005,
      PropPlacement = {0.1820, 0.2400, 0.0600, -69.3774235, 5.9142048, -13.9572354},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["binoculars"] = {"amb@world_human_binoculars@male@idle_b", "idle_f", "望遠鏡", AnimationOptions =
   {
      Prop = "prop_binoc_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["binoculars2"] = {"amb@world_human_binoculars@male@idle_a", "idle_c", "望遠鏡 2", AnimationOptions =
   {
      Prop = "prop_binoc_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tennisplay"] = {"move_weapon@jerrycan@generic", "idle", "打網球", AnimationOptions =
   {
      Prop = "prop_tennis_bag_01",
      PropBone = 57005,
      PropPlacement = {0.27, 0.0, 0.0, 91.0, 0.0, -82.9999951},
      SecondProp = 'prop_tennis_rack_01',
      SecondPropBone = 60309,
      SecondPropPlacement = {0.0800, 0.0300, 0.0, -130.2907295, 3.8782324, 6.588224},
      EmoteLoop = true,
      EmoteMoving = true,


   }},
   ["weights"] = {"amb@world_human_muscle_free_weights@male@barbell@base", "base", "Weights", AnimationOptions =
   {
      Prop = "prop_curl_bar_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["weights2"] = {"amb@world_human_muscle_free_weights@male@barbell@idle_a", "idle_d", "Weights 2", AnimationOptions =
   {
      Prop = "prop_curl_bar_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["fuel"] = {"weapons@misc@jerrycan@", "fire", "燃料", AnimationOptions =
   {
      Prop = "w_am_jerrycan",
      PropBone = 57005,
      PropPlacement = {0.1800, 0.1300, -0.2400, -165.8693883, -11.2122753, -32.9453021},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["fuel2"] = {"weapons@misc@jerrycan@franklin", "idle", "燃料 2 (拎住)", AnimationOptions =
   {
      Prop = "w_am_jerrycan",
      PropBone = 28422,
      PropPlacement = {0.26, 0.050, 0.0300, 80.00, 180.000, 79.99},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["hitchhike"] = {"random@hitch_lift", "idle_f", "順風車", AnimationOptions =
   {
      Prop = "w_am_jerrycan",
      PropBone = 18905,
      PropPlacement = {0.32, -0.0100, 0.0, -162.423, 74.83, 58.79},
      SecondProp = 'prop_michael_backpack',
      SecondPropBone = 40269,
      SecondPropPlacement = {-0.07, -0.21, -0.11, -144.93, 117.358, -6.16},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 停 路牌 ", AnimationOptions =
   {
      Prop = "prop_sign_road_01a",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign2"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 讓 路牌 ", AnimationOptions =
   {
      Prop = "prop_sign_road_02a",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign3"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 醫院 路牌 ", AnimationOptions =
   {
      Prop = "prop_sign_road_03d",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign4"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 泊車 路牌 ", AnimationOptions =
   {
      Prop = "prop_sign_road_04a",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign5"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 泊車 路牌 2 ", AnimationOptions =
   {
      Prop = "prop_sign_road_04w",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign6"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 行人 路牌 ", AnimationOptions =
   {
      Prop = "prop_sign_road_05a",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign7"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 跣胎 路牌 ", AnimationOptions =
   {
      Prop = "prop_sign_road_05t",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign8"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 高速公路 路牌 ", AnimationOptions =
   {
      Prop = "prop_sign_freewayentrance",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["ssign9"] = {"rcmnigel1d", "base_club_shoulder", "偷左個 停 路牌 有雪 ", AnimationOptions =
   {
      Prop = "prop_snow_sign_road_01a",
      PropBone = 60309,
      PropPlacement = {-0.1390, -0.9870, 0.4300, -67.3315314, 145.0627869, -4.4318885},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["conehead"] = {"move_m@drunk@verydrunk_idles@", "fidget_07", "雪榚筒", AnimationOptions =
   {
      Prop = "prop_roadcone02b",
      PropBone = 31086,
      PropPlacement = {0.0500, 0.0200, -0.000, 30.0000004, 90.0, 0.0},
      --
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtraya"] = {"anim@heists@box_carry@", "idle", "食物托盤", AnimationOptions =
   {
      Prop = "prop_food_bs_tray_03",
      PropBone = 28422,
      PropPlacement = {0.0100, -0.0400, -0.1390,20.0000007, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayb"] = {"anim@heists@box_carry@", "idle", "食物托盤 B", AnimationOptions =
   {
      Prop = "prop_food_bs_tray_02",
      PropBone = 28422,
      PropPlacement = {0.0100, -0.0400, -0.1390,20.0000007, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayc"] = {"anim@heists@box_carry@", "idle", "食物托盤 C", AnimationOptions =
   {
      Prop = "prop_food_cb_tray_02",
      PropBone = 28422,
      PropPlacement = {0.0100, -0.0400, -0.1390,20.0000007, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayd"] = {"anim@heists@box_carry@", "idle", "食物托盤 D", AnimationOptions =
   {
      Prop = "prop_food_tray_02",
      PropBone = 28422,
      PropPlacement = {0.0100, -0.0400, -0.1390,20.0000007, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtraye"] = {"anim@heists@box_carry@", "idle", "食物托盤 E", AnimationOptions =
   {
      Prop = "prop_food_tray_03",
      PropBone = 28422,
      PropPlacement = {0.0100, -0.0400, -0.1390,20.0000007, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayf"] = {"anim@heists@box_carry@", "idle", "食物托盤 F", AnimationOptions =
   {
      Prop = "prop_food_bs_tray_02",
      PropBone = 57005,
      PropPlacement = {0.2500, 0.1000, 0.0700,-110.5483936, 73.3529273, -16.338362},
      SecondProp = 'prop_food_bs_tray_03',
      SecondPropBone =18905,
      SecondPropPlacement = {0.2200, 0.1300, -0.1000, -127.7725487, 110.2074758, -3.5886263},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayg"] = {"anim@heists@box_carry@", "idle", "食物托盤 G", AnimationOptions =
   {
      Prop = "prop_food_cb_tray_02",
      PropBone = 57005,
      PropPlacement = {0.2500, 0.1000, 0.0700,-110.5483936, 73.3529273, -16.338362},
      SecondProp = 'prop_food_cb_tray_02',
      SecondPropBone =18905,
      SecondPropPlacement = {0.2200, 0.1300, -0.1000, -127.7725487, 110.2074758, -3.5886263},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayh"] = {"anim@heists@box_carry@", "idle", "食物托盤 H", AnimationOptions =
   {
      Prop = "prop_food_tray_02",
      PropBone = 57005,
      PropPlacement = {0.2500, 0.1000, 0.0700,-110.5483936, 73.3529273, -16.338362},
      SecondProp = 'prop_food_tray_03',
      SecondPropBone =18905,
      SecondPropPlacement = {0.2200, 0.1300, -0.1000, -127.7725487, 110.2074758, -3.5886263},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayi"] = {"anim@heists@box_carry@", "idle", "食物托盤 I", AnimationOptions =
   {
      Prop = "prop_food_tray_02",
      PropBone = 57005,
      PropPlacement = {0.2500, 0.1000, 0.0700,-110.5483936, 73.3529273, -16.338362},
      SecondProp = 'prop_food_tray_02',
      SecondPropBone =18905,
      SecondPropPlacement = {0.2200, 0.1300, -0.1000, -127.7725487, 110.2074758, -3.5886263},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayj"] = {"anim@move_f@waitress", "idle", "食物托盤 J", AnimationOptions =
   {
      Prop = "prop_food_bs_tray_02",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0200,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayk"] = {"anim@move_f@waitress", "idle", "食物托盤 K", AnimationOptions =
   {
      Prop = "prop_food_bs_tray_02",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0200,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayl"] = {"anim@move_f@waitress", "idle", "食物托盤 L", AnimationOptions =
   {
      Prop = "prop_food_bs_tray_03",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0200,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtraym"] = {"anim@move_f@waitress", "idle", "食物托盤 M", AnimationOptions =
   {
      Prop = "prop_food_cb_tray_02",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0200,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayn"] = {"anim@move_f@waitress", "idle", "食物托盤 N", AnimationOptions =
   {
      Prop = "prop_food_tray_02",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0200,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["foodtrayo"] = {"anim@move_f@waitress", "idle", "食物托盤 O", AnimationOptions =
   {
      Prop = "prop_food_tray_02",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0200,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["carrypizza"] = {"anim@heists@box_carry@", "idle", "拎住Pizza盒", AnimationOptions =
   {
      Prop = "prop_pizza_box_02",
      PropBone = 28422,
      PropPlacement = {0.0100, -0.1000, -0.1590,20.0000007, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["carryfoodbag"] = {"move_weapon@jerrycan@generic", "idle", "拎住食物袋", AnimationOptions =
   {
      Prop = "prop_food_bs_bag_01",
      PropBone = 57005,
      PropPlacement = {0.3300, 0.0, -0.0300, 0.0017365, -79.9999997, 110.0651988},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["carryfoodbag2"] = {"move_weapon@jerrycan@generic", "idle", "拎住食物袋 2", AnimationOptions =
   {
      Prop = "prop_food_cb_bag_01",
      PropBone = 57005,
      PropPlacement = {0.3800, 0.0, -0.0300, 0.0017365, -79.9999997, 110.0651988},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["carryfoodbag3"] = {"move_weapon@jerrycan@generic", "idle", "拎住食物袋 3", AnimationOptions =
   {
      Prop = "prop_food_bag1",
      PropBone = 57005,
      PropPlacement = {0.3800, 0.0, -0.0300, 0.0017365, -79.9999997, 110.0651988},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tag"] = {"anim@scripted@freemode@postertag@graffiti_spray@male@", "shake_can_male", "塗鴉 搖罐 男性", AnimationOptions =
   {
      Prop = "prop_cs_spray_can",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0700, 0.0017365, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tag2"] = {"anim@scripted@freemode@postertag@graffiti_spray@heeled@", "shake_can_female", "塗鴉 搖罐 女性", AnimationOptions =
   {
      Prop = "prop_cs_spray_can",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0700, 0.0017365, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tag3"] = {"anim@scripted@freemode@postertag@graffiti_spray@male@", "spray_can_var_01_male", "塗鴉 男性 1", AnimationOptions =
   {
      Prop = "prop_cs_spray_can",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0700, 0.0017365, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tag4"] = {"anim@scripted@freemode@postertag@graffiti_spray@male@", "spray_can_var_02_male", "塗鴉 男性 2", AnimationOptions =
   {
      Prop = "prop_cs_spray_can",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0700, 0.0017365, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tag5"] = {"anim@scripted@freemode@postertag@graffiti_spray@heeled@", "spray_can_var_01_female", "塗鴉 女性 1", AnimationOptions =
   {
      Prop = "prop_cs_spray_can",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0700, 0.0017365, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["tag6"] = {"anim@scripted@freemode@postertag@graffiti_spray@heeled@", "spray_can_var_02_female", "塗鴉 女性 2", AnimationOptions =
   {
      Prop = "prop_cs_spray_can",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0700, 0.0017365, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["beans"] = {"anim@scripted@island@special_peds@pavel@hs4_pavel_ig5_caviar_p1", "base_idle", "Beans", AnimationOptions =
   {
      Prop = "h4_prop_h4_caviar_tin_01a",
      PropBone = 60309,
      PropPlacement = {0.0, 0.0300, 0.0100,0.0,0.0,0.0},
      SecondProp = 'h4_prop_h4_caviar_spoon_01a',
      SecondPropBone = 28422,
      SecondPropPlacement = {0.0,0.0,0.0,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   --[[["newscam"] = {"missfinale_c2mcs_1", "fin_c2_mcs_1_camman", "News Camera", AnimationOptions =
   {
      Prop = "prop_v_cam_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0300, 0.0100,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["newsmic"] = {"anim@heists@humane_labs@finale@keycards", "ped_a_enter_loop", "News Microphone", AnimationOptions =
   {
      Prop = "p_ing_microphonel_01",
      PropBone = 4154,
      PropPlacement = {-0.00, -0.0200, 0.1100, 0.00, 0.0, 60.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["newsbmic"] = {"missfra1", "mcs2_crew_idle_m_boom", "News Boom Microphone", AnimationOptions =
   {
      Prop = "prop_v_bmike_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},]]
   ["leafblower"] = {"amb@world_human_gardener_leaf_blower@base", "base", "吹葉機", AnimationOptions =
   {
      Prop = "prop_leaf_blower_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["bbqf"] = {"amb@prop_human_bbq@male@idle_a", "idle_b", "BBQ (女性)", AnimationOptions =
   {
      Prop = "prop_fish_slice_01",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["pump"] = {"missfbi4prepp1", "idle", "南瓜", AnimationOptions =
   {
      Prop = "prop_veg_crop_03_pump",
      PropBone = 28422,
      PropPlacement = {0.0200, 0.0600, -0.1200, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["pump2"] = {"anim@heists@box_carry@", "idle", "南瓜 2", AnimationOptions =
   {
      Prop = "prop_veg_crop_03_pump",
      PropBone = 28422,
      PropPlacement = {0.0100, -0.16000, -0.2100, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["mop"] = {"missfbi4prepp1", "idle", "拖把", AnimationOptions =
   {
      Prop = "prop_cs_mop_s",
      PropBone = 28422,
      PropPlacement = {-0.0200,-0.0600,-0.2000, -13.377, 10.3568, 17.9681},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["mop2"] = {"move_mop", "idle_scrub_small_player", "拖把 2", AnimationOptions =
   {
      Prop = "prop_cs_mop_s",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.1200, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["jerkf"] = {"switch@trevor@jerking_off", "trev_jerking_off_loop", "JerkOff! Female", AnimationOptions =
   {
      Prop = 'prop_cs_dildo_01',
      PropBone = 28422,
      PropPlacement = {0.09, 0.05, -0.03, 90.0, 80.0, 30.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["rake"] = {"anim@amb@drug_field_workers@rake@male_a@base", "base", "犁耙", AnimationOptions =
   {
      Prop = "prop_tool_rake",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, -0.0300, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["rake2"] = {"anim@amb@drug_field_workers@rake@male_a@idles", "idle_b", "犁耙 2", AnimationOptions =
   {
      Prop = "prop_tool_rake",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, -0.0300, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["rake3"] = {"anim@amb@drug_field_workers@rake@male_b@base", "base", "犁耙 3", AnimationOptions =
   {
      Prop = "prop_tool_rake",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, -0.0300, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["rake4"] = {"anim@amb@drug_field_workers@rake@male_b@idles", "idle_d", "犁耙 4", AnimationOptions =
   {
      Prop = "prop_tool_rake",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, -0.0300, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["broom"] = {"anim@amb@drug_field_workers@rake@male_a@base", "base", "掃把", AnimationOptions =
   {
      Prop = "prop_tool_broom",
      PropBone = 28422,
      PropPlacement = {-0.0100, 0.0400, -0.0300, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["broom2"] = {"anim@amb@drug_field_workers@rake@male_a@idles", "idle_b", "掃把 2", AnimationOptions =
   {
      Prop = "prop_tool_broom",
      PropBone = 28422,
      PropPlacement = {-0.0100, 0.0400, -0.0300, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["broom3"] = {"anim@amb@drug_field_workers@rake@male_b@base", "base", "掃把 3", AnimationOptions =
   {
      Prop = "prop_tool_broom",
      PropBone = 28422,
      PropPlacement = {-0.0100, 0.0400, -0.0300, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["broom4"] = {"anim@amb@drug_field_workers@rake@male_b@idles", "idle_d", "掃把 4", AnimationOptions =
   {
      Prop = "prop_tool_broom",
      PropBone = 28422,
      PropPlacement = {-0.0100, 0.0400, -0.0300, 0.0, 0.0, 0.0},
      EmoteLoop = true,
   }},
   ["champw"] = {"anim@move_f@waitress", "idle", "拎香檳 待應", AnimationOptions =
   {
      Prop = "vw_prop_vw_tray_01a",
      PropBone = 28422,
      PropPlacement = {0.0, 0.0, 0.0100,0.0,0.0,0.0},
      SecondProp = 'prop_champ_cool',
      SecondPropBone = 28422,
      SecondPropPlacement = {0.0,0.0,0.010,0.0,0.0,0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
   ["shit"] = {"missfbi3ig_0", "shit_loop_trev", "屙屎", AnimationOptions =
   {
      Prop = "prop_toilet_roll_01",
      PropBone = 28422,
      PropPlacement = {0.0700, -0.02000, -0.2100, 0,0, 0.0, 0.0},
      SecondProp = 'prop_big_shit_01',
      SecondPropBone = 0,
      SecondPropPlacement = {-0.0100, 0.0600, -0.1550, 101.3015175, 7.3512213,-29.2665794},
      EmoteLoop = true,
      EmoteMoving = false,
   }},
   ["selfie"] = {"anim@mp_player_intuppertake_selfie", "idle_a", "自拍", AnimationOptions =
   {
      Prop = "prop_phone_ing",
      PropBone = 60309,
      PropPlacement = {0.0, 0.0,0.0, 0.0, 0.0, 0.0},
      EmoteLoop = true,
      EmoteMoving = true,
   }},
}