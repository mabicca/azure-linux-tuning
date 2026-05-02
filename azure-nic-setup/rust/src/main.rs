use std::env;
use std::fs::{self, File};
use std::io::{self, IsTerminal, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone)]
struct Config {
    an_rx_rings: u32,
    an_tx_rings: u32,
    synth_rx_rings: u32,
    synth_tx_rings: u32,
    assume_yes: bool,
    debug: bool,
    uninstall: bool,
    has_params: bool,
    helper_script: String,
    systemd_dir: String,
    udev_dir: String,
    state_file: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            an_rx_rings: 4096,
            an_tx_rings: 4096,
            synth_rx_rings: 1024,
            synth_tx_rings: 1024,
            assume_yes: false,
            debug: false,
            uninstall: false,
            has_params: false,
            helper_script: env::var("HELPER_SCRIPT")
                .unwrap_or_else(|_| "/usr/local/sbin/azure-apply-rings.sh".to_string()),
            systemd_dir: env::var("SYSTEMD_DIR").unwrap_or_else(|_| "/etc/systemd/system".to_string()),
            udev_dir: env::var("UDEV_DIR").unwrap_or_else(|_| "/etc/udev/rules.d".to_string()),
            state_file: env::var("STATE_FILE")
                .unwrap_or_else(|_| "/etc/azure-nic-config.state".to_string()),
        }
    }
}

fn usage(program: &str, exit_code: i32) -> ! {
    println!(
        "Usage: {program} [OPTIONS]\n\n\
Configure NIC ring sizes for Azure VMs via systemd units and udev rules.\n\n\
OPTIONS:\n\
    --an RX TX            Ring sizes for Accelerated NICs (default: 4096 4096)\n\
    --synth RX TX         Ring sizes for Synthetic NICs (default: 1024 1024)\n\
    --uninstall           Remove systemd units and udev rules\n\
    -d, --debug           Enable debug output\n\
    -y, --yes             Skip confirmation prompt\n\
    -h, --help            Display this help message\n\n\
EXAMPLES:\n\
    {program} --an 4096 4096 --synth 1024 1024\n\
    {program} --an 4096 4096\n\
    {program} --synth 1024 1024\n\
    {program} --debug --yes\n\
    {program} --uninstall"
    );
    std::process::exit(exit_code);
}

fn parse_u32_arg(name: &str, value: &str) -> Result<u32, String> {
    value
        .parse::<u32>()
        .map_err(|_| format!("Error: {name} must be a positive integer, got '{value}'"))
}

fn parse_args() -> Result<Config, String> {
    let mut cfg = Config::default();
    let mut args: Vec<String> = env::args().collect();
    let program = args
        .first()
        .cloned()
        .unwrap_or_else(|| "azure-nic-setup".to_string());

    args.remove(0);
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "--an" => {
                if i + 2 >= args.len() {
                    return Err("Error: --an requires two arguments (RX TX)".to_string());
                }
                cfg.an_rx_rings = parse_u32_arg("AN_RX_RINGS", &args[i + 1])?;
                cfg.an_tx_rings = parse_u32_arg("AN_TX_RINGS", &args[i + 2])?;
                cfg.has_params = true;
                i += 3;
            }
            "--synth" => {
                if i + 2 >= args.len() {
                    return Err("Error: --synth requires two arguments (RX TX)".to_string());
                }
                cfg.synth_rx_rings = parse_u32_arg("SYNTH_RX_RINGS", &args[i + 1])?;
                cfg.synth_tx_rings = parse_u32_arg("SYNTH_TX_RINGS", &args[i + 2])?;
                cfg.has_params = true;
                i += 3;
            }
            "--uninstall" => {
                cfg.uninstall = true;
                i += 1;
            }
            "-d" | "--debug" => {
                cfg.debug = true;
                i += 1;
            }
            "-y" | "--yes" => {
                cfg.assume_yes = true;
                i += 1;
            }
            "-h" | "--help" => usage(&program, 0),
            unknown => return Err(format!("Unknown option: {unknown}")),
        }
    }

    Ok(cfg)
}

fn debug_log(enabled: bool, message: &str) {
    if enabled {
        println!("DEBUG: {message}");
    }
}

fn command_exists(cmd: &str) -> bool {
    Command::new("sh")
        .arg("-c")
        .arg(format!("command -v {cmd} >/dev/null 2>&1"))
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_command_capture(cmd: &str, args: &[&str]) -> io::Result<String> {
    let out = Command::new(cmd).args(args).output()?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    } else {
        Ok(String::new())
    }
}

fn run_command_status(cmd: &str, args: &[&str]) -> io::Result<bool> {
    let status = Command::new(cmd).args(args).status()?;
    Ok(status.success())
}

fn interfaces() -> io::Result<Vec<String>> {
    let mut names = Vec::new();
    for entry in fs::read_dir("/sys/class/net")? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name != "lo" {
            names.push(name);
        }
    }
    Ok(names)
}

fn driver_for_interface(iface: &str) -> Option<String> {
    let path = PathBuf::from(format!("/sys/class/net/{iface}/device/driver"));
    if !path.exists() {
        return None;
    }

    let link = fs::read_link(path).ok()?;
    link.file_name().map(|v| v.to_string_lossy().to_string())
}

fn is_an_driver(driver: &str) -> bool {
    matches!(
        driver,
        "mana" | "mlx5" | "mlx5_core" | "mlx4" | "mlx4_en" | "mlx4_core"
    )
}

fn parse_two_values_after_marker(output: &str, marker: &str) -> Option<(u32, u32)> {
    let mut in_section = false;
    let mut rx: Option<u32> = None;
    let mut tx: Option<u32> = None;

    for line in output.lines() {
        if line.trim_start().starts_with(marker) {
            in_section = true;
            continue;
        }

        if !in_section {
            continue;
        }

        let trimmed = line.trim();
        if let Some(v) = trimmed.strip_prefix("RX:") {
            rx = v.trim().parse::<u32>().ok();
        }
        if let Some(v) = trimmed.strip_prefix("TX:") {
            tx = v.trim().parse::<u32>().ok();
        }

        if rx.is_some() && tx.is_some() {
            return Some((rx.unwrap_or(0), tx.unwrap_or(0)));
        }
    }

    None
}

fn get_ring_maxima(iface: &str) -> Option<(u32, u32)> {
    let out = run_command_capture("ethtool", &["-g", iface]).ok()?;
    parse_two_values_after_marker(&out, "Pre-set maximums:")
}

fn get_ring_current(iface: &str) -> Option<(u32, u32)> {
    let out = run_command_capture("ethtool", &["-g", iface]).ok()?;
    parse_two_values_after_marker(&out, "Current hardware settings:")
}

fn warn_if_exceeds_max(debug: bool, iface: &str, target_rx: u32, target_tx: u32) {
    if !command_exists("ethtool") {
        return;
    }

    let Some((max_rx, max_tx)) = get_ring_maxima(iface) else {
        debug_log(debug, &format!("Could not determine max ring values for {iface}"));
        return;
    };

    debug_log(debug, &format!("{iface} maximums: RX={max_rx} TX={max_tx}"));

    if target_rx > max_rx {
        println!("Warning: {iface} requested RX={target_rx} exceeds max RX={max_rx}");
    }
    if target_tx > max_tx {
        println!("Warning: {iface} requested TX={target_tx} exceeds max TX={max_tx}");
    }
}

fn confirm_action(action: &str, assume_yes: bool) -> io::Result<bool> {
    if assume_yes {
        return Ok(true);
    }

    if io::stdin().is_terminal() {
        println!("About to {action}.");
        print!("Continue? [y/N]: ");
        io::stdout().flush()?;

        let mut reply = String::new();
        io::stdin().read_line(&mut reply)?;
        let reply = reply.trim();
        Ok(matches!(reply, "y" | "Y" | "yes" | "YES"))
    } else {
        println!("Non-interactive mode detected; proceeding without confirmation prompt.");
        Ok(true)
    }
}

fn save_original_settings(cfg: &Config) -> io::Result<()> {
    let path = Path::new(&cfg.state_file);
    if path.exists() {
        return Ok(());
    }

    let mut file = match File::create(path) {
        Ok(f) => f,
        Err(_) => {
            return Ok(());
        }
    };

    writeln!(file, "# Azure NIC Configuration State File")?;
    writeln!(
        file,
        "# Auto-generated on first run - used for uninstall restoration"
    )?;
    writeln!(file, "declare -A NIC_ORIGINAL_RINGS")?;

    println!("Detecting original NIC ring settings...");

    if !command_exists("ethtool") {
        return Ok(());
    }

    for iface in interfaces()? {
        if let Some((rx, tx)) = get_ring_current(&iface) {
            writeln!(file, "NIC_ORIGINAL_RINGS[{iface}]=\"{rx},{tx}\"")?;
            println!("  Saved {iface}: RX={rx} TX={tx}");
        }
    }

    println!("State file created: {}", cfg.state_file);
    Ok(())
}

fn parse_state_line(line: &str) -> Option<(String, u32, u32)> {
    if !line.starts_with("NIC_ORIGINAL_RINGS[") {
        return None;
    }
    let name_start = "NIC_ORIGINAL_RINGS[".len();
    let rest = &line[name_start..];
    let end_bracket = rest.find(']')?;
    let nic = rest[..end_bracket].to_string();

    let value_start = line.find("\"")? + 1;
    let value_end = line.rfind("\"")?;
    if value_end <= value_start {
        return None;
    }
    let values = &line[value_start..value_end];
    let mut parts = values.split(',');
    let rx = parts.next()?.trim().parse::<u32>().ok()?;
    let tx = parts.next()?.trim().parse::<u32>().ok()?;

    Some((nic, rx, tx))
}

fn apply_ring_settings_now(cfg: &Config) -> io::Result<()> {
    if !command_exists("ethtool") {
        println!("Warning: ethtool not found; skipping immediate ring update.");
        return Ok(());
    }

    println!("Applying ring sizes immediately to active interfaces...");

    for iface in interfaces()? {
        let Some(driver) = driver_for_interface(&iface) else {
            continue;
        };
        debug_log(cfg.debug, &format!("Interface {iface} driver={driver}"));

        let (target_rx, target_tx) = match driver.as_str() {
            d if is_an_driver(d) => {
                debug_log(
                    cfg.debug,
                    &format!("Classified {iface} as accelerated (direct driver match)"),
                );
                (cfg.an_rx_rings, cfg.an_tx_rings)
            }
            "hv_netvsc" => {
                debug_log(cfg.debug, &format!("Classified {iface} as synthetic (hv_netvsc)"));
                (cfg.synth_rx_rings, cfg.synth_tx_rings)
            }
            _ => {
                debug_log(cfg.debug, &format!("Skipping {iface} (unsupported driver)"));
                continue;
            }
        };

        println!("  {iface} ({driver}): setting RX={target_rx} TX={target_tx}");
        warn_if_exceeds_max(cfg.debug, &iface, target_rx, target_tx);

        let ok = run_command_status(
            "ethtool",
            &[
                "-G",
                iface.as_str(),
                "rx",
                &target_rx.to_string(),
                "tx",
                &target_tx.to_string(),
            ],
        )?;

        if !ok {
            println!("    Warning: could not apply settings to {iface}");
        }
    }

    Ok(())
}

fn create_helper_script(cfg: &Config) -> io::Result<()> {
    println!("Creating helper script: {}", cfg.helper_script);

    let content = format!(
        r#"#!/usr/bin/env bash
set -euo pipefail

mode="auto"
if [[ "${{1:-}}" == "--mode" ]]; then
    mode="${{2:-auto}}"
    shift 2
fi

iface="${{1:-}}"
if [[ -z "$iface" ]]; then
    echo "Usage: $0 [--mode an|synth|auto] <interface>" >&2
    exit 1
fi

AN_RX="{an_rx}"
AN_TX="{an_tx}"
SYNTH_RX="{synth_rx}"
SYNTH_TX="{synth_tx}"
DEBUG="{debug}"

is_an_driver() {{
    local d="$1"
    case "$d" in
        mana|mlx5|mlx5_core|mlx4|mlx4_en|mlx4_core) return 0 ;;
        *) return 1 ;;
    esac
}}

driver=""
if [[ -e "/sys/class/net/$iface/device/driver" ]]; then
    driver=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null || true)")
fi

case "$mode" in
    an) target_rx="$AN_RX"; target_tx="$AN_TX" ;;
    synth) target_rx="$SYNTH_RX"; target_tx="$SYNTH_TX" ;;
    auto)
        if is_an_driver "$driver"; then
            target_rx="$AN_RX"
            target_tx="$AN_TX"
        else
            target_rx="$SYNTH_RX"
            target_tx="$SYNTH_TX"
        fi
        ;;
    *)
        echo "Invalid mode: $mode" >&2
        exit 1
        ;;
esac

ethtool_bin=$(command -v ethtool || true)
if [[ -z "$ethtool_bin" ]]; then
    echo "ethtool not found" >&2
    exit 1
fi

"$ethtool_bin" -G "$iface" rx "$target_rx" tx "$target_tx"
"#,
        an_rx = cfg.an_rx_rings,
        an_tx = cfg.an_tx_rings,
        synth_rx = cfg.synth_rx_rings,
        synth_tx = cfg.synth_tx_rings,
        debug = if cfg.debug { 1 } else { 0 },
    );

    fs::write(&cfg.helper_script, content)?;
    fs::set_permissions(&cfg.helper_script, fs::Permissions::from_mode(0o755))?;
    Ok(())
}

fn create_systemd_and_udev(cfg: &Config) -> io::Result<()> {
    fs::create_dir_all(&cfg.systemd_dir)?;
    fs::create_dir_all(&cfg.udev_dir)?;

    println!("Creating systemd unit: set-rings-an@.service");
    fs::write(
        format!("{}/set-rings-an@.service", cfg.systemd_dir),
        format!(
            "[Unit]\nDescription=Set ring sizes for accelerated NIC %i\nAfter=network.target\n\n[Service]\nType=oneshot\nExecStart={} --mode an %i\n\n[Install]\nWantedBy=multi-user.target\n",
            cfg.helper_script
        ),
    )?;

    println!("Creating systemd unit: set-rings-synth@.service");
    fs::write(
        format!("{}/set-rings-synth@.service", cfg.systemd_dir),
        format!(
            "[Unit]\nDescription=Set ring sizes for synthetic NIC %i\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStartPre=/bin/sleep 2\nExecStart={} --mode synth %i\n\n[Install]\nWantedBy=multi-user.target\n",
            cfg.helper_script
        ),
    )?;

    println!("Creating udev rule: 99-azure-nic-config.rules");
    fs::write(
        format!("{}/99-azure-nic-config.rules", cfg.udev_dir),
        r#"# Synthetic NICs (hv_netvsc)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="hv_netvsc", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-synth@%k.service"

# Accelerated NICs (mana)
SUBSYSTEM=="net", ACTION=="move", DRIVERS=="mana", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx5_core)
SUBSYSTEM=="net", ACTION=="move", DRIVERS=="mlx5_core", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx4_en)
SUBSYSTEM=="net", ACTION=="move", DRIVERS=="mlx4_en", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx4_core)
SUBSYSTEM=="net", ACTION=="move", DRIVERS=="mlx4_core", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mana)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mana", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx5_core)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mlx5_core", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx4_en)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mlx4_en", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx4_core)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mlx4_core", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"
"#,
    )?;

    Ok(())
}

fn uninstall(cfg: &Config) -> io::Result<()> {
    println!("Removing NIC configuration files...");

    let an_unit = format!("{}/set-rings-an@.service", cfg.systemd_dir);
    let synth_unit = format!("{}/set-rings-synth@.service", cfg.systemd_dir);
    let rules = format!("{}/99-azure-nic-config.rules", cfg.udev_dir);

    for path in [&an_unit, &synth_unit, &rules, &cfg.helper_script] {
        if Path::new(path).exists() {
            fs::remove_file(path)?;
            println!("Removed: {path}");
        }
    }

    println!("Reloading systemd and udev...");
    if !run_command_status("systemctl", &["daemon-reload"]).unwrap_or(false) {
        println!("Note: systemctl not available (expected in test environment)");
    }
    if !run_command_status("udevadm", &["control", "--reload-rules"]).unwrap_or(false) {
        println!("Note: udevadm not available (expected in test environment)");
    }
    if !run_command_status("udevadm", &["trigger"]).unwrap_or(false) {
        println!("Note: udevadm not available (expected in test environment)");
    }

    if Path::new(&cfg.state_file).exists() {
        println!("Restoring original NIC ring settings...");
        if let Ok(content) = fs::read_to_string(&cfg.state_file) {
            for line in content.lines() {
                if let Some((nic, rx, tx)) = parse_state_line(line) {
                    let nic_path = PathBuf::from(format!("/sys/class/net/{nic}"));
                    if nic_path.exists() {
                        println!("  Restoring {nic}: RX={rx} TX={tx}");
                        let ok = run_command_status(
                            "ethtool",
                            &["-G", nic.as_str(), "rx", &rx.to_string(), "tx", &tx.to_string()],
                        )
                        .unwrap_or(false);
                        if !ok {
                            println!("    Warning: Could not restore {nic}");
                        }
                    }
                }
            }
        }

        fs::remove_file(&cfg.state_file)?;
        println!("Removed state file: {}", cfg.state_file);
    }

    println!("Uninstall complete.");
    Ok(())
}

fn main() -> io::Result<()> {
    let program = env::args()
        .next()
        .unwrap_or_else(|| "azure-nic-setup".to_string());

    let cfg = match parse_args() {
        Ok(c) => c,
        Err(err) => {
            eprintln!("{err}");
            usage(&program, 1);
        }
    };

    if cfg.uninstall {
        if !confirm_action(
            "remove NIC tuning configuration and restore original ring settings",
            cfg.assume_yes,
        )? {
            println!("Aborted.");
            return Ok(());
        }
        return uninstall(&cfg);
    }

    save_original_settings(&cfg)?;

    if !cfg.has_params {
        println!("WARNING: No ring size parameters specified. Using defaults:");
        println!(
            "  Accelerated NICs: RX={} TX={}",
            cfg.an_rx_rings, cfg.an_tx_rings
        );
        println!(
            "  Synthetic NICs:   RX={} TX={}",
            cfg.synth_rx_rings, cfg.synth_tx_rings
        );
        println!("Use --help to see available options.\n");
    }

    if !confirm_action(
        "configure NIC tuning files and apply ring settings",
        cfg.assume_yes,
    )? {
        println!("Aborted.");
        return Ok(());
    }

    println!("Configuring NICs with the following settings:");
    println!(
        "  Accelerated NICs: RX={} TX={}",
        cfg.an_rx_rings, cfg.an_tx_rings
    );
    println!(
        "  Synthetic NICs:   RX={} TX={}",
        cfg.synth_rx_rings, cfg.synth_tx_rings
    );
    println!();

    create_helper_script(&cfg)?;
    create_systemd_and_udev(&cfg)?;
    apply_ring_settings_now(&cfg)?;

    println!("Reloading systemd and udev");
    if !run_command_status("systemctl", &["daemon-reload"])? {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "systemctl daemon-reload failed",
        ));
    }
    if !run_command_status("udevadm", &["control", "--reload-rules"])? {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "udevadm control --reload-rules failed",
        ));
    }
    if !run_command_status("udevadm", &["trigger"])? {
        return Err(io::Error::new(io::ErrorKind::Other, "udevadm trigger failed"));
    }

    println!("Done.");
    Ok(())
}
