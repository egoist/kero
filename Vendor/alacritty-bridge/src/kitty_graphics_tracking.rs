//! Keeps Kitty image placements attached to Alacritty's scrolling grid.
//!
//! Adapted from Termy's implementation at
//! https://github.com/lassejlv/termy/tree/d094009217c278701abdecf906dc1903e6b01bc5
//! under the MIT license in `../TERMY_LICENSE`.

use crate::kitty_graphics::{KittyGraphicsScreen, KittyGraphicsState};
use alacritty_terminal::{
    event::EventListener,
    grid::Dimensions,
    term::{Term, TermMode},
    vte::ansi::{self, Handler, NamedPrivateMode, PrivateMode},
};
use unicode_width::UnicodeWidthChar;

#[derive(Clone, Copy, Debug)]
struct ScrollRegion {
    top: usize,
    bottom: Option<usize>,
}

impl Default for ScrollRegion {
    fn default() -> Self {
        Self {
            top: 1,
            bottom: None,
        }
    }
}

impl ScrollRegion {
    fn bounds(self, screen_lines: usize) -> (usize, usize) {
        let top = self.top.saturating_sub(1).min(screen_lines);
        let bottom = self.bottom.unwrap_or(screen_lines).min(screen_lines);
        (top, bottom)
    }

    fn covers_full_screen(self, screen_lines: usize) -> bool {
        self.bounds(screen_lines) == (0, screen_lines)
    }

    fn set(&mut self, top: usize, bottom: Option<usize>, screen_lines: usize) {
        if top >= bottom.unwrap_or(screen_lines) {
            return;
        }
        self.top = top;
        self.bottom = bottom;
    }

    fn reset(&mut self) {
        self.top = 1;
        self.bottom = None;
    }
}

#[derive(Default)]
pub(crate) struct KittyGraphicsCursorTracker {
    region: ScrollRegion,
}

impl KittyGraphicsCursorTracker {
    pub(crate) fn region_covers_full_screen(&self, screen_lines: usize) -> bool {
        self.region.covers_full_screen(screen_lines)
    }

    pub(crate) fn reset_scroll_region(&mut self) {
        self.region.reset();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TextEffect {
    EnteredAlternateScreen,
    TerminalReset,
    PreservePrimaryAcrossPartialHistoryGrowth(usize),
    ScrollUpWithoutHistory {
        screen: KittyGraphicsScreen,
        lines: usize,
    },
    ClearViewport {
        screen: KittyGraphicsScreen,
        history_size: usize,
        rows: usize,
        columns: usize,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct KittyGraphicsTextEffects {
    effects: Vec<TextEffect>,
}

impl KittyGraphicsTextEffects {
    pub(crate) fn apply_to(self, graphics: &mut KittyGraphicsState) -> bool {
        let mut changed = false;
        for effect in self.effects {
            changed |= match effect {
                TextEffect::EnteredAlternateScreen => {
                    graphics.clear_screen(KittyGraphicsScreen::Alternate)
                }
                TextEffect::TerminalReset => {
                    let primary = graphics.clear_screen(KittyGraphicsScreen::Primary);
                    let alternate = graphics.clear_screen(KittyGraphicsScreen::Alternate);
                    primary || alternate
                }
                TextEffect::PreservePrimaryAcrossPartialHistoryGrowth(lines) => {
                    graphics.preserve_primary_across_partial_history_growth(lines)
                }
                TextEffect::ScrollUpWithoutHistory { screen, lines } => {
                    graphics.scroll_up_without_history(lines, screen)
                }
                TextEffect::ClearViewport {
                    screen,
                    history_size,
                    rows,
                    columns,
                } => graphics.clear_viewport(screen, history_size, rows, columns),
            };
        }
        changed
    }

    fn push(&mut self, effect: TextEffect) {
        self.effects.push(effect);
    }
}

#[derive(Clone, Copy, Debug)]
struct ScrollObservation {
    screen: KittyGraphicsScreen,
    full_screen_region: bool,
    physical_lines: usize,
    history_before: usize,
}

struct TrackingHandler<'a, T> {
    term: &'a mut Term<T>,
    tracker: &'a mut KittyGraphicsCursorTracker,
    effects: &'a mut KittyGraphicsTextEffects,
    track_scrolls: bool,
}

impl<T: EventListener> TrackingHandler<'_, T> {
    fn linefeed_scroll_lines(&self) -> usize {
        let screen_lines = self.term.grid().screen_lines();
        let (_, bottom) = self.tracker.region.bounds(screen_lines);
        let cursor_line = self.term.grid().cursor.point.line.0.max(0) as usize;
        usize::from(screen_lines > 0 && cursor_line.saturating_add(1) == bottom)
    }

    fn input_scroll_lines(&self, character: char) -> usize {
        let Some(width) = character.width() else {
            return 0;
        };
        if width == 0 || !self.term.mode().contains(TermMode::LINE_WRAP) {
            return 0;
        }
        let cursor = &self.term.grid().cursor;
        let needs_wrap = cursor.input_needs_wrap
            || (width == 2
                && cursor.point.column.0.saturating_add(1) >= self.term.grid().columns());
        if needs_wrap {
            self.linefeed_scroll_lines()
        } else {
            0
        }
    }

    fn explicit_scroll_up_lines(&self, lines: usize) -> usize {
        let screen_lines = self.term.grid().screen_lines();
        let (top, bottom) = self.tracker.region.bounds(screen_lines);
        lines.min(bottom.saturating_sub(top))
    }

    fn observe_scroll(&self, physical_lines: usize) -> Option<ScrollObservation> {
        if !self.track_scrolls || physical_lines == 0 {
            return None;
        }
        let screen_lines = self.term.grid().screen_lines();
        Some(ScrollObservation {
            screen: KittyGraphicsScreen::from_alternate_screen(
                self.term.mode().contains(TermMode::ALT_SCREEN),
            ),
            full_screen_region: self.tracker.region.covers_full_screen(screen_lines),
            physical_lines,
            history_before: self.term.grid().history_size(),
        })
    }

    fn finish_scroll(&mut self, observation: Option<ScrollObservation>) {
        let Some(observation) = observation else {
            return;
        };
        let history_growth = self
            .term
            .grid()
            .history_size()
            .saturating_sub(observation.history_before);
        match (observation.screen, observation.full_screen_region) {
            (KittyGraphicsScreen::Primary, true) => {
                let lines = observation.physical_lines.saturating_sub(history_growth);
                if lines > 0 {
                    self.effects.push(TextEffect::ScrollUpWithoutHistory {
                        screen: KittyGraphicsScreen::Primary,
                        lines,
                    });
                }
            }
            (KittyGraphicsScreen::Primary, false) => {
                if history_growth > 0 {
                    self.effects
                        .push(TextEffect::PreservePrimaryAcrossPartialHistoryGrowth(
                            history_growth,
                        ));
                }
            }
            (KittyGraphicsScreen::Alternate, true) => {
                self.effects.push(TextEffect::ScrollUpWithoutHistory {
                    screen: KittyGraphicsScreen::Alternate,
                    lines: observation.physical_lines,
                });
            }
            (KittyGraphicsScreen::Alternate, false) => {}
        }
    }
}

macro_rules! forward_handler_methods {
    ($(fn $name:ident($($arg:ident: $ty:ty),*);)*) => {
        $(
            fn $name(&mut self $(, $arg: $ty)*) {
                Handler::$name(&mut *self.term $(, $arg)*);
            }
        )*
    };
}

impl<T: EventListener> Handler for TrackingHandler<'_, T> {
    fn input(&mut self, character: char) {
        let physical_lines = if self.track_scrolls {
            self.input_scroll_lines(character)
        } else {
            0
        };
        let observation = self.observe_scroll(physical_lines);
        Handler::input(&mut *self.term, character);
        self.finish_scroll(observation);
    }

    fn put_tab(&mut self, count: u16) {
        let physical_lines = if self.track_scrolls
            && self.term.grid().cursor.input_needs_wrap
            && self.term.mode().contains(TermMode::LINE_WRAP)
        {
            self.linefeed_scroll_lines()
        } else {
            0
        };
        let observation = self.observe_scroll(physical_lines);
        Handler::put_tab(&mut *self.term, count);
        self.finish_scroll(observation);
    }

    fn linefeed(&mut self) {
        let physical_lines = if self.track_scrolls {
            self.linefeed_scroll_lines()
        } else {
            0
        };
        let observation = self.observe_scroll(physical_lines);
        Handler::linefeed(&mut *self.term);
        self.finish_scroll(observation);
    }

    fn newline(&mut self) {
        let physical_lines = if self.track_scrolls {
            self.linefeed_scroll_lines()
        } else {
            0
        };
        let observation = self.observe_scroll(physical_lines);
        Handler::newline(&mut *self.term);
        self.finish_scroll(observation);
    }

    fn scroll_up(&mut self, lines: usize) {
        let physical_lines = if self.track_scrolls {
            self.explicit_scroll_up_lines(lines)
        } else {
            0
        };
        let observation = self.observe_scroll(physical_lines);
        Handler::scroll_up(&mut *self.term, lines);
        self.finish_scroll(observation);
    }

    fn reset_state(&mut self) {
        self.tracker.reset_scroll_region();
        self.effects.push(TextEffect::TerminalReset);
        Handler::reset_state(&mut *self.term);
    }

    fn set_private_mode(&mut self, mode: PrivateMode) {
        if mode == NamedPrivateMode::ColumnMode.into() {
            self.tracker.reset_scroll_region();
        }
        if mode == NamedPrivateMode::SwapScreenAndSetRestoreCursor.into()
            && !self.term.mode().contains(TermMode::ALT_SCREEN)
        {
            self.effects.push(TextEffect::EnteredAlternateScreen);
        }
        Handler::set_private_mode(&mut *self.term, mode);
    }

    fn unset_private_mode(&mut self, mode: PrivateMode) {
        if mode == NamedPrivateMode::ColumnMode.into() {
            self.tracker.reset_scroll_region();
        }
        Handler::unset_private_mode(&mut *self.term, mode);
    }

    fn set_scrolling_region(&mut self, top: usize, bottom: Option<usize>) {
        self.tracker
            .region
            .set(top, bottom, self.term.grid().screen_lines());
        Handler::set_scrolling_region(&mut *self.term, top, bottom);
    }

    fn clear_screen(&mut self, mode: ansi::ClearMode) {
        let clear_viewport = if self.track_scrolls && matches!(mode, ansi::ClearMode::All) {
            Some(TextEffect::ClearViewport {
                screen: KittyGraphicsScreen::from_alternate_screen(
                    self.term.mode().contains(TermMode::ALT_SCREEN),
                ),
                history_size: self.term.grid().history_size(),
                rows: self.term.grid().screen_lines(),
                columns: self.term.grid().columns(),
            })
        } else {
            None
        };
        Handler::clear_screen(&mut *self.term, mode);
        if let Some(clear_viewport) = clear_viewport {
            self.effects.push(clear_viewport);
        }
    }

    forward_handler_methods! {
        fn set_title(title: Option<String>);
        fn set_cursor_style(style: Option<ansi::CursorStyle>);
        fn set_cursor_shape(shape: ansi::CursorShape);
        fn goto(line: i32, column: usize);
        fn goto_line(line: i32);
        fn goto_col(column: usize);
        fn insert_blank(count: usize);
        fn move_up(rows: usize);
        fn move_down(rows: usize);
        fn identify_terminal(intermediate: Option<char>);
        fn device_status(status: usize);
        fn move_forward(columns: usize);
        fn move_backward(columns: usize);
        fn move_down_and_cr(rows: usize);
        fn move_up_and_cr(rows: usize);
        fn backspace();
        fn carriage_return();
        fn bell();
        fn substitute();
        fn set_horizontal_tabstop();
        fn scroll_down(rows: usize);
        fn insert_blank_lines(lines: usize);
        fn delete_lines(lines: usize);
        fn erase_chars(count: usize);
        fn delete_chars(count: usize);
        fn move_backward_tabs(count: u16);
        fn move_forward_tabs(count: u16);
        fn save_cursor_position();
        fn restore_cursor_position();
        fn clear_line(mode: ansi::LineClearMode);
        fn clear_tabs(mode: ansi::TabulationClearMode);
        fn set_tabs(interval: u16);
        fn reverse_index();
        fn terminal_attribute(attr: ansi::Attr);
        fn set_mode(mode: ansi::Mode);
        fn unset_mode(mode: ansi::Mode);
        fn report_mode(mode: ansi::Mode);
        fn report_private_mode(mode: ansi::PrivateMode);
        fn set_keypad_application_mode();
        fn unset_keypad_application_mode();
        fn set_active_charset(index: ansi::CharsetIndex);
        fn configure_charset(index: ansi::CharsetIndex, charset: ansi::StandardCharset);
        fn set_color(index: usize, color: ansi::Rgb);
        fn dynamic_color_sequence(prefix: String, index: usize, terminator: &str);
        fn reset_color(index: usize);
        fn clipboard_store(clipboard: u8, data: &[u8]);
        fn clipboard_load(clipboard: u8, terminator: &str);
        fn decaln();
        fn push_title();
        fn pop_title();
        fn text_area_size_pixels();
        fn text_area_size_chars();
        fn set_hyperlink(hyperlink: Option<ansi::Hyperlink>);
        fn set_mouse_cursor_icon(icon: ansi::cursor_icon::CursorIcon);
        fn report_keyboard_mode();
        fn push_keyboard_mode(mode: ansi::KeyboardModes);
        fn pop_keyboard_modes(to_pop: u16);
        fn set_keyboard_mode(mode: ansi::KeyboardModes, behavior: ansi::KeyboardModesApplyBehavior);
        fn set_modify_other_keys(mode: ansi::ModifyOtherKeys);
        fn report_modify_other_keys();
        fn set_scp(char_path: ansi::ScpCharPath, update_mode: ansi::ScpUpdateMode);
    }
}

pub(crate) fn advance_text<T: EventListener>(
    tracker: &mut KittyGraphicsCursorTracker,
    parser: &mut ansi::Processor,
    term: &mut Term<T>,
    bytes: &[u8],
    track_scrolls: bool,
) -> KittyGraphicsTextEffects {
    let mut effects = KittyGraphicsTextEffects::default();
    {
        let mut handler = TrackingHandler {
            term,
            tracker,
            effects: &mut effects,
            track_scrolls,
        };
        parser.advance(&mut handler, bytes);
    }
    effects
}

pub(crate) fn advance_cursor<T: EventListener>(
    term: &mut Term<T>,
    columns: u32,
    rows: u32,
    full_screen_scroll_region: bool,
) -> usize {
    let columns = usize::try_from(columns)
        .unwrap_or(usize::MAX)
        .min(term.grid().columns());
    Handler::move_forward(term, columns);

    let rows = usize::try_from(rows)
        .unwrap_or(usize::MAX)
        .min(term.grid().screen_lines());
    if !full_screen_scroll_region {
        Handler::move_down(term, rows);
        return 0;
    }

    let history_before = term.grid().history_size();
    let mut scrolled_lines = 0;
    for _ in 0..rows {
        let line_before = term.grid().cursor.point.line;
        Handler::linefeed(term);
        scrolled_lines += usize::from(term.grid().cursor.point.line == line_before);
    }
    let history_growth = term.grid().history_size().saturating_sub(history_before);
    scrolled_lines.saturating_sub(history_growth)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::{event::VoidListener, term::Config};

    #[test]
    fn synchronized_cursor_move_is_visible_after_stopping_sync() {
        let size = crate::TermSize {
            columns: 80,
            screen_lines: 24,
        };
        let mut term = Term::new(Config::default(), &size, VoidListener);
        let mut parser = ansi::Processor::new();
        let mut tracker = KittyGraphicsCursorTracker::default();

        advance_text(
            &mut tracker,
            &mut parser,
            &mut term,
            b"\x1b[?2026h\x1b[10;5H",
            false,
        );

        assert_eq!(term.grid().cursor.point.line.0, 0);
        assert_eq!(term.grid().cursor.point.column.0, 0);
        assert!(parser.sync_bytes_count() > 0);

        parser.stop_sync(&mut term);

        assert_eq!(term.grid().cursor.point.line.0, 9);
        assert_eq!(term.grid().cursor.point.column.0, 4);
    }
}
