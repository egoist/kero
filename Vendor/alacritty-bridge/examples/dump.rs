//! Headless harness: drives the bridge exactly as Kero does and prints the
//! grid as text plus per-cell flags.
//!
//! This exists to tell an emulator bug from a renderer bug without AppKit in
//! the way. Run it with the commands to type:
//!
//!     cargo run --example dump -- "cd /tmp" "ls"

use std::ffi::{c_void, CString};
use std::thread::sleep;
use std::time::Duration;

use kero_alacritty::*;

extern "C" fn on_event(_context: *mut c_void, kind: u32, _data: *const u8, _len: usize) {
    if kind == KERO_EVENT_EXIT {
        eprintln!("[event] exit");
    }
}

fn main() {
    let mut commands: Vec<String> = std::env::args().skip(1).collect();
    // Trailing `--find <needle>` runs a search after the commands.
    let needle = commands
        .iter()
        .position(|argument| argument == "--find")
        .map(|index| {
            let value = commands[index + 1].clone();
            commands.truncate(index);
            value
        });
    // Trailing `--scroll <lines>` scrolls back before snapshotting.
    let scroll: i32 = commands
        .iter()
        .position(|argument| argument == "--scroll")
        .map(|index| {
            let value = commands[index + 1].parse().unwrap_or(0);
            commands.truncate(index);
            value
        })
        .unwrap_or(0);

    let shell = CString::new("/bin/sh").unwrap();
    let arg = CString::new("-c").unwrap();
    let script = CString::new("exec /bin/zsh -f -i").unwrap();
    let directory = CString::new("/tmp").unwrap();
    let term = CString::new("TERM=xterm-256color").unwrap();

    let args = [arg.as_ptr(), script.as_ptr()];
    let env = [term.as_ptr()];

    let config = KeroConfig {
        shell: shell.as_ptr(),
        args: args.as_ptr(),
        args_len: args.len(),
        working_directory: directory.as_ptr(),
        env: env.as_ptr(),
        env_len: env.len(),
        columns: 80,
        rows: 24,
        cell_width: 8,
        cell_height: 16,
        scrollback_lines: 1000,
    };

    let mut theme = KeroTheme {
        palette: [0; 256],
        foreground: 0xffffff,
        background: 0,
        cursor: 0xffffff,
    };
    for (index, slot) in theme.palette.iter_mut().enumerate() {
        *slot = (index as u32) * 0x010101;
    }

    let handle = unsafe { kero_alacritty_new(&config, &theme, on_event, std::ptr::null_mut()) };
    assert!(!handle.is_null(), "failed to spawn");
    sleep(Duration::from_millis(600));

    for command in &commands {
        let line = format!("{command}\n");
        unsafe { kero_alacritty_write(handle, line.as_ptr(), line.len()) };
        sleep(Duration::from_millis(700));
    }
    sleep(Duration::from_millis(400));

    if scroll != 0 {
        unsafe { kero_alacritty_scroll(handle, scroll) };
        sleep(Duration::from_millis(100));
    }

    let mut snapshot = KeroSnapshot {
        cells: std::ptr::null(),
        columns: 0,
        rows: 0,
        cursor_line: 0,
        cursor_column: 0,
        cursor_shape: 0,
        cursor_color: 0,
        background: 0,
        cursor_blinking: false,
        text: std::ptr::null(),
        text_len: 0,
        display_offset: 0,
        total_lines: 0,
        screen_lines: 0,
    };
    unsafe { kero_alacritty_snapshot(handle, &mut snapshot) };

    if let Some(needle) = needle {
        let c_needle = CString::new(needle.clone()).unwrap();
        let count = unsafe { kero_alacritty_find(handle, c_needle.as_ptr()) };
        println!("find {needle:?} -> {count} matches");
        for _ in 0..count.min(3) {
            let index = unsafe { kero_alacritty_find_step(handle, true) };
            println!("  stepped to {index}");
        }
    }

    println!(
        "grid {}x{} display_offset={} total={} screen={}",
        snapshot.columns,
        snapshot.rows,
        snapshot.display_offset,
        snapshot.total_lines,
        snapshot.screen_lines
    );
    for row in 0..snapshot.rows {
        let mut text = String::new();
        let mut flagged = Vec::new();
        for column in 0..snapshot.columns {
            let cell = unsafe { *snapshot.cells.add(row * snapshot.columns + column) };
            text.push(char::from_u32(cell.ch).unwrap_or('?'));
            if cell.flags != 0 {
                flagged.push(format!("{column}:{:#x}", cell.flags));
            }
        }
        let trimmed = text.trim_end();
        if trimmed.is_empty() && flagged.is_empty() {
            continue;
        }
        println!("{row:>3} |{trimmed}|");
        if !flagged.is_empty() {
            println!("    flags {}", flagged.join(" "));
        }
    }

    unsafe { kero_alacritty_free(handle) };
}
