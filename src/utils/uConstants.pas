unit uConstants;

{$mode objfpc}{$H+}

interface

const
  // ===========================================================================
  // APPLICATION METADATA
  // ===========================================================================
  APP_TITLE   = 'ABYSSAL TERMINAL : MARIANA OS';
  APP_VERSION = 'v1.4.1-QA-BALANCED'; // Updated version indicating QA patch
  OS_PROMPT   = 'MARIANA_OS> ';

  // ===========================================================================
  // FILE & ASSET PATHS (Relative to executable in /bin)
  // ===========================================================================
  PATH_DB_FILE         = '..\db\mariana_os.db';
  PATH_DB_MEMORY       = ':memory:';

  PATH_FONT_RETRO      = '..\assets\fonts\VT323-Regular.ttf';

  PATH_IMG_SCANLINES   = '..\assets\graphics\crt_scanlines.png';
  PATH_IMG_VIGNETTE    = '..\assets\graphics\crt_vignette.png';

  PATH_SND_PING        = '..\assets\audio\ping_active.wav';
  PATH_SND_RUMBLE      = '..\assets\audio\ambient_rumble.wav';
  PATH_SND_ALARM       = '..\assets\audio\alarm_pressure.wav';
  PATH_SND_MONSTER     = '..\assets\audio\monster_lowfreq.wav';

  // ===========================================================================
  // ENGINE & RENDER TIMING
  // ===========================================================================
  ENGINE_TICK_MS       = 16;     // ~60 FPS / 60 Hz Physics & Render Tick
  TELEMETRY_LOG_MS     = 1000;   // Log telemetry to DB every 1 second
  CHART_UPDATE_MS      = 100;    // 10 Hz update rate for TAChart (CPU optimization)
  FFT_SAMPLE_COUNT     = 128;    // Number of frequency bins for audio visualizer
  BOOT_SEQ_DELAY_MS    = 350;    // Delay between lines during faux BIOS boot
  BOOT_SEQ_LINES       = 9;      // Number of fake initialization steps

  // ===========================================================================
  // WORLD & HYDROSTATIC PHYSICS CONSTANTS
  // ===========================================================================
  SURFACE_PSI          = 14.7;     // Atmospheric pressure at sea level
  PSI_PER_METER        = 1.47;     // Seawater hydrostatic increase (~1 atm per 10m)
  MAX_TRENCH_DEPTH     = 11000.0;  // Absolute floor limit (Meters)
  TARGET_MISSION_DEPTH = 10900.0;  // Win condition target depth (Meters)

  // Pressure differential limits (External PSI vs Internal Equalized PSI)
  SAFE_PSI_DIFF        = 150.0;    // Threshold before hull stress begins
  CRITICAL_PSI_DIFF    = 450.0;    // Threshold for rapid hull degradation & alarms
  IMPLOSION_PSI_DIFF   = 800.0;    // Instant hull failure threshold

  // Signal latency mechanics (Umbilical cord degradation at depth)
  LATENCY_START_DEPTH  = 3000.0;   // Depth where command delay begins (Meters)
  MAX_SIGNAL_LATENCY   = 2200;     // (QA Fixed) Max delay 2.2s for fair human reaction

  // ===========================================================================
  // BATHYSCAPHE & RESOURCE SPECIFICATIONS
  // ===========================================================================
  MAX_HULL_INTEGRITY   = 100.0;
  MAX_BATTERY_RESERVE  = 100.0;
  CLI_HISTORY_LIMIT    = 15;       // Maximum commands kept in memory for UP arrow recall

  BASE_DESCENT_RATE    = 12.0;     // (QA Fixed) Increased to make a session last ~15 mins
  MAX_THRUSTER_SPEED   = 18.0;     // (QA Fixed) Max thrust speed for dodging / diving fast
  VALVE_PURGE_RATE     = 95.0;     // (QA Fixed) Slightly faster purge to handle new speed

  // Power consumption rates (% of battery per second at 100% allocation)
  DRAIN_CORE_OS        = 0.015;    // (QA Fixed) Optimized baseline drain
  DRAIN_SONAR_PASSIVE  = 0.02;     // (QA Fixed) Optimized baseline drain
  DRAIN_SONAR_ACTIVE   = 0.22;     // Increased active sonar drain to force ping-and-hide
  DRAIN_THRUSTERS      = 0.35;     // Propulsion draw during active maneuver
  DRAIN_DRILL_SYSTEM   = 0.65;     // Heavy extraction laser/mechanical drill draw
  DRAIN_DRILL_JAM      = 2.50;     // Severe penalty drain when drill is jammed
  COST_DEPLOY_DECOY    = 15.0;     // Instant battery % cost to deploy sonar decoy

  // Mission Objectives
  REQUIRED_MINERALS    = 3;        // Number of samples needed to complete mission
  DRILL_CYCLE_SECONDS  = 12.0;     // Time required to extract 1 mineral sample
  DRILL_JAM_PROB       = 15;       // % chance for the drill to jam during a cycle

  // ===========================================================================
  // SONAR, ANOMALY & GLITCH PARAMETERS
  // ===========================================================================
  SONAR_MAX_RANGE      = 500.0;    // Radar radius in meters
  SONAR_SWEEP_SPEED    = 140.0;    // Radar sweep rotation (Degrees per second)
  SONAR_BLIP_FADE_RATE = 0.45;     // Phosphor persistence decay rate per second

  ANOMALY_DETECT_RANGE = 450.0;    // Distance where anomaly appears on active sonar
  ANOMALY_AGGRO_RANGE  = 250.0;    // Distance where active ping attracts the entity
  ANOMALY_STRIKE_RANGE = 35.0;     // Distance for physical collision/hull strike
  ANOMALY_BASE_SPEED   = 26.0;     // (QA Fixed) Leviathan must be faster than ship descent!

  DECOY_LIFETIME       = 8.0;      // Seconds a decoy remains active before failing

  GLITCH_SYNTAX_THRESH = 40.0;     // Hull integrity % below which CLI syntax degrades
  GLITCH_EM_RANGE      = 180.0;    // Anomaly proximity causing EM UI distortion

  // EMP Blackout Parameters
  EMP_REBOOT_TIME      = 5.5;      // (QA Fixed) Increased to 5.5s to make blackouts terrifying

  // ===========================================================================
  // VISUAL & CRT COLOR PALETTES (TColor format: $00BBGGRR)
  // ===========================================================================
  CLR_BG_TERMINAL      = $00080A05; // Deep CRT Pitch Black-Green
  CLR_BG_PANEL         = $0010140C; // Control Board Dark Frame

  // Theme 1: Classic Phosphor Green
  CLR_GREEN_PRIMARY    = $0014FF39; // #39FF14 Neon Phosphor Green
  CLR_GREEN_DIM        = $000A6617; // Dimmed grid/inactive elements
  CLR_GREEN_GLOW       = $0066FF80; // Highlight/Sweep line

  // Theme 2: Retro Amber
  CLR_AMBER_PRIMARY    = $0000B0FF; // #FFB000 CRT Amber
  CLR_AMBER_DIM        = $00004866; // Dimmed Amber
  CLR_AMBER_GLOW       = $004DC8FF; // Highlight Amber

  // Alert States
  CLR_ALERT_WARN       = $0000D5FF; // Warning Orange/Yellow
  CLR_ALERT_CRITICAL   = $002020FF; // Critical Crimson Red

  // ===========================================================================
  // CLI COMMAND TOKENS & SYSTEM MESSAGES (ENGLISH UI)
  // ===========================================================================
  CMD_HELP             = 'help';
  CMD_STATUS           = 'status';
  CMD_CLEAR            = 'clear';
  CMD_SONAR            = 'sonar';          // e.g., sonar -mode active | passive
  CMD_THRUSTER         = 'thruster';       // e.g., thruster -dir up|down|N|S|E|W -pwr 80
  CMD_STOP             = 'thruster_stop';
  CMD_PURGE            = 'purge_valve';    // Equalize internal pressure
  CMD_ROUTE            = 'route_power';    // e.g., route_power -sys sonar -val 50
  CMD_DRILL            = 'run';            // e.g., run drill_sequence | run sys_diag | run sys_reboot
  CMD_DECOY            = 'deploy_decoy';   // Deploy acoustic decoy
  CMD_READ_LOG         = 'read_log';       // e.g., read_log 1

  ARG_DRILL_SEQ        = 'drill_sequence';
  ARG_DRILL_REV        = 'drill_reverse';
  ARG_SYS_DIAG         = 'sys_diag';
  ARG_SYS_REBOOT       = 'sys_reboot';

  // Standard System Log Notifications
  MSG_BOOT_SEQ         = '[SYS] MARIANA OS KERNEL INITIALIZED. UMBILICAL LINK ESTABLISHED.';
  MSG_SONAR_ACTIVE     = '[SYS] ACOUSTIC TRANSDUCER ONLINE: ACTIVE PING ENABLED.';
  MSG_SONAR_PASSIVE    = '[SYS] ACOUSTIC TRANSDUCER SILENCED: PASSIVE HYDROPHONE MODE.';
  MSG_PRESSURE_WARN    = '[WARN] HYDROSTATIC DIFFERENTIAL HIGH. MANUAL PURGE RECOMMENDED.';
  MSG_PRESSURE_CRIT    = '[CRIT] HULL STRESS CRITICAL! IMPLOSION IMMINENT!';
  MSG_ENTITY_DETECT    = '[WARN] UNIDENTIFIED BIOLOGICAL MASS DETECTED IN SECTOR.';
  MSG_ENTITY_PROXIMITY = '[CRIT] MASSIVE ACOUSTIC SIGNATURE APPROACHING! SILENCE SONAR!';
  MSG_BUFFER_CORRUPT   = '[ERR] EM INTERFERENCE DETECTED. CLI MEMORY BUFFER CORRUPTED.';
  MSG_DIAG_COMPLETE    = '[SYS] DIAGNOSTIC COMPLETE. CLI MEMORY BUFFER RESTORED.';

  MSG_DRILL_START      = '[SYS] LASER DRILL DEPLOYED. EXTRACTING...';
  MSG_DRILL_SUCCESS    = '[SYS] MINERAL SAMPLE SECURED IN CONTAINMENT BAY.';
  MSG_BLACKBOX_SUCCESS = '[SYS] ENCRYPTED FLIGHT RECORDER (BLACKBOX) RECOVERED. RUN "read_log" TO DECRYPT.';
  MSG_DRILL_JAM        = '[CRIT] DRILL BIT STALLED! OVERHEAT IMMINENT. RUN "run drill_reverse" TO CLEAR!';
  MSG_DRILL_REV        = '[SYS] DRILL REVERSING. CLEARING DEBRIS...';

  MSG_DECOY_DEPLOY     = '[SYS] ACOUSTIC DECOY DEPLOYED. BROADCASTING FALSE SIGNATURE.';
  MSG_EMP_STRIKE       = '[FATAL] MASSIVE EMP SURGE DETECTED! TERMINAL KERNEL PANIC!';
  MSG_REBOOT_INIT      = '[SYS] INITIATING EMERGENCY COLD REBOOT...';
  MSG_ERR_SYNTAX       = '[ERR] UNKNOWN COMMAND OR INVALID SYNTAX. TYPE "HELP".';

  // ===========================================================================
  // LORE TEXTS (BLACKBOX RECOVERY LOGS)
  // ===========================================================================
  BLACKBOX_LORE: array[0..5] of string = (
    'LOG #014: "The sonar... it''s not echoing off the trench walls. The walls are moving. It''s circling us."',
    'LOG #042: "Battery at 5%. We deployed all decoys, but it doesn''t care about sound anymore. It can smell the reactor."',
    'LOG #089: "I''m manually purging the valve. The pressure won''t kill us as fast as whatever is outside that viewport."',
    'LOG #112: "We found the minerals... but they''re not rocks. They''re eggs. God help us, the drill woke it up."',
    'LOG #156: "EMP blackout. We are blind. I can hear it scraping against the titanium hull. It''s playing with us."',
    'LOG #204: "Surface command, if you receive this... do not send another vessel. The trench belongs to it now."'
  );

implementation

end.
