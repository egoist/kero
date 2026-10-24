//! Alacritty's PTY event loop with Kitty graphics interception at the parser
//! boundary, so image commands observe the exact live cursor and scroll state.
//!
//! The structure follows `alacritty_terminal::event_loop` and Termy's native
//! runtime loop. Termy's MIT license is in `../TERMY_LICENSE`.

use crate::{
    kitty_graphics::{
        KittyGraphicsInterceptor, KittyGraphicsItem, KittyGraphicsScreen, KittyGraphicsSize,
        KittyGraphicsStore,
    },
    kitty_graphics_tracking::{advance_cursor, advance_text, KittyGraphicsCursorTracker},
};
use alacritty_terminal::{
    event::{Event, EventListener, Notify, OnResize, WindowSize},
    grid::Dimensions,
    sync::FairMutex,
    term::{Term, TermMode},
    tty,
    vte::ansi,
};
use polling::{Event as PollingEvent, Events, PollMode, Poller};
use std::{
    borrow::Cow,
    collections::VecDeque,
    io::{self, ErrorKind, Read, Write},
    num::NonZeroUsize,
    sync::{
        mpsc::{self, Receiver, Sender, TryRecvError},
        Arc,
    },
    thread::JoinHandle,
    time::Instant,
};

const READ_BUFFER_SIZE: usize = 0x10_0000;
const MAX_LOCKED_READ: usize = u16::MAX as usize;
const PTY_READ_WRITE_TOKEN: usize = 0;
const PTY_CHILD_EVENT_TOKEN: usize = 1;

#[derive(Debug)]
pub(crate) enum GraphicsMsg {
    Input(Cow<'static, [u8]>),
    Shutdown,
    Resize(WindowSize),
}

pub(crate) struct GraphicsEventLoop<T: tty::EventedPty, U: EventListener> {
    poller: Arc<Poller>,
    pty: T,
    receiver: PeekableReceiver<GraphicsMsg>,
    sender: Sender<GraphicsMsg>,
    terminal: Arc<FairMutex<Term<U>>>,
    event_proxy: U,
    graphics: Arc<FairMutex<KittyGraphicsStore>>,
    graphics_size: Arc<FairMutex<KittyGraphicsSize>>,
}

impl<T, U> GraphicsEventLoop<T, U>
where
    T: tty::EventedPty + OnResize + Send + 'static,
    U: EventListener + Send + 'static,
{
    pub(crate) fn new(
        terminal: Arc<FairMutex<Term<U>>>,
        event_proxy: U,
        pty: T,
        graphics: Arc<FairMutex<KittyGraphicsStore>>,
        graphics_size: Arc<FairMutex<KittyGraphicsSize>>,
    ) -> io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        let poller = Arc::new(Poller::new()?);
        Ok(Self {
            poller,
            pty,
            receiver: PeekableReceiver::new(receiver),
            sender,
            terminal,
            event_proxy,
            graphics,
            graphics_size,
        })
    }

    pub(crate) fn channel(&self) -> GraphicsEventLoopSender {
        GraphicsEventLoopSender {
            sender: self.sender.clone(),
            poller: self.poller.clone(),
        }
    }

    fn drain_messages(&mut self, state: &mut GraphicsEventLoopState) -> bool {
        while let Some(message) = self.receiver.recv() {
            match message {
                GraphicsMsg::Input(input) => state.write_list.push_back(input),
                GraphicsMsg::Resize(size) => {
                    state.graphics_cursor_tracker.reset_scroll_region();
                    self.pty.on_resize(size);
                }
                GraphicsMsg::Shutdown => return false,
            }
        }
        true
    }

    fn parse_output(
        &self,
        state: &mut GraphicsEventLoopState,
        terminal: &mut Term<U>,
        bytes: &[u8],
    ) -> bool {
        let mut graphics_changed = false;
        for item in state.graphics_interceptor.process(bytes) {
            match item {
                KittyGraphicsItem::Text(text) => {
                    let track_scrolls = self.graphics.lock().state.has_placements();
                    let effects = advance_text(
                        &mut state.graphics_cursor_tracker,
                        &mut state.parser,
                        terminal,
                        &text,
                        track_scrolls,
                    );
                    let mut graphics = self.graphics.lock();
                    if effects.apply_to(&mut graphics.state) {
                        graphics.mark_changed();
                        graphics_changed = true;
                    }
                }
                KittyGraphicsItem::Command(command) => {
                    // Alacritty buffers everything between DECSET/DECRST 2026,
                    // including cursor movement. Kitty commands are intercepted
                    // outside that parser, so commit the buffered terminal
                    // operations before reading the cursor used to anchor an
                    // image placement. Kero still suppresses presentation until
                    // the outer synchronized update ends, preserving atomicity.
                    if state.parser.sync_bytes_count() > 0 {
                        state.parser.stop_sync(terminal);
                    }
                    let cursor = terminal.grid().cursor.point;
                    let screen = KittyGraphicsScreen::from_alternate_screen(
                        terminal.mode().contains(TermMode::ALT_SCREEN),
                    );
                    let full_screen_scroll_region = state
                        .graphics_cursor_tracker
                        .region_covers_full_screen(terminal.grid().screen_lines());
                    let mut size = *self.graphics_size.lock();
                    size.columns = terminal.grid().columns();
                    size.rows = terminal.grid().screen_lines();
                    let result = {
                        let mut graphics = self.graphics.lock();
                        let result = graphics.state.apply(
                            command,
                            cursor.column.0,
                            cursor.line.0.max(0) as usize,
                            terminal.grid().history_size(),
                            size,
                            screen,
                        );
                        if result.changed {
                            graphics.mark_changed();
                        }
                        result
                    };
                    if let Some(response) = result.response {
                        state.write_list.push_back(Cow::Owned(response));
                    }
                    graphics_changed |= result.changed;
                    if result.cursor_advance_screen == Some(screen) {
                        if let Some((columns, rows)) = result.cursor_advance {
                            let untracked_scroll =
                                advance_cursor(terminal, columns, rows, full_screen_scroll_region);
                            if untracked_scroll > 0 {
                                let mut graphics = self.graphics.lock();
                                if graphics
                                    .state
                                    .scroll_up_without_history(untracked_scroll, screen)
                                {
                                    graphics.mark_changed();
                                    graphics_changed = true;
                                }
                            }
                        }
                    }
                }
            }
        }
        graphics_changed
    }

    fn pty_read(
        &mut self,
        state: &mut GraphicsEventLoopState,
        buffer: &mut [u8],
    ) -> io::Result<()> {
        let mut unprocessed = 0;
        let mut processed = 0;
        let mut graphics_changed = false;
        let _terminal_lease = self.terminal.lease();
        let mut terminal = None;

        loop {
            match self.pty.reader().read(&mut buffer[unprocessed..]) {
                Ok(0) if unprocessed == 0 => break,
                Ok(count) => unprocessed += count,
                Err(error) => match error.kind() {
                    ErrorKind::Interrupted | ErrorKind::WouldBlock => {
                        if unprocessed == 0 {
                            break;
                        }
                    }
                    _ => return Err(error),
                },
            }

            let terminal = match &mut terminal {
                Some(terminal) => terminal,
                None => terminal.insert(match self.terminal.try_lock_unfair() {
                    None if unprocessed >= READ_BUFFER_SIZE => self.terminal.lock_unfair(),
                    None => continue,
                    Some(terminal) => terminal,
                }),
            };

            graphics_changed |= self.parse_output(state, &mut **terminal, &buffer[..unprocessed]);
            processed += unprocessed;
            unprocessed = 0;

            if processed >= MAX_LOCKED_READ {
                break;
            }
        }

        if graphics_changed || (state.parser.sync_bytes_count() < processed && processed > 0) {
            self.event_proxy.send_event(Event::Wakeup);
        }
        Ok(())
    }

    fn pty_write(&mut self, state: &mut GraphicsEventLoopState) -> io::Result<()> {
        state.ensure_next();
        'write_many: while let Some(mut current) = state.take_current() {
            'write_one: loop {
                match self.pty.writer().write(current.remaining_bytes()) {
                    Ok(0) => {
                        state.set_current(Some(current));
                        break 'write_many;
                    }
                    Ok(count) => {
                        current.advance(count);
                        if current.finished() {
                            state.goto_next();
                            break 'write_one;
                        }
                    }
                    Err(error) => {
                        state.set_current(Some(current));
                        match error.kind() {
                            ErrorKind::Interrupted | ErrorKind::WouldBlock => break 'write_many,
                            _ => return Err(error),
                        }
                    }
                }
            }
        }
        Ok(())
    }

    pub(crate) fn spawn(mut self) -> JoinHandle<()> {
        std::thread::Builder::new()
            .name("Kero Alacritty PTY".into())
            .spawn(move || {
                let mut state = GraphicsEventLoopState::default();
                let mut buffer = [0u8; READ_BUFFER_SIZE];
                let poll_mode = PollMode::Level;
                let mut interest = PollingEvent::readable(0);

                if let Err(error) = unsafe { self.pty.register(&self.poller, interest, poll_mode) }
                {
                    eprintln!("kero: Alacritty event loop registration failed: {error}");
                    return;
                }

                let mut events = Events::with_capacity(NonZeroUsize::new(1024).unwrap());
                'event_loop: loop {
                    let timeout = state
                        .parser
                        .sync_timeout()
                        .sync_timeout()
                        .map(|timeout| timeout.saturating_duration_since(Instant::now()));
                    events.clear();
                    if let Err(error) = self.poller.wait(&mut events, timeout) {
                        match error.kind() {
                            ErrorKind::Interrupted => continue,
                            _ => {
                                eprintln!("kero: Alacritty polling failed: {error}");
                                break;
                            }
                        }
                    }

                    if events.is_empty() && self.receiver.peek().is_none() {
                        state.parser.stop_sync(&mut *self.terminal.lock());
                        self.event_proxy.send_event(Event::Wakeup);
                        continue;
                    }
                    if !self.drain_messages(&mut state) {
                        break;
                    }

                    for event in events.iter() {
                        match event.key {
                            PTY_CHILD_EVENT_TOKEN => {
                                if let Some(tty::ChildEvent::Exited(status)) =
                                    self.pty.next_child_event()
                                {
                                    if let Some(status) = status {
                                        self.event_proxy.send_event(Event::ChildExit(status));
                                    }
                                    self.terminal.lock().exit();
                                    self.event_proxy.send_event(Event::Wakeup);
                                    break 'event_loop;
                                }
                            }
                            PTY_READ_WRITE_TOKEN => {
                                if event.is_interrupt() {
                                    continue;
                                }
                                if event.readable {
                                    if let Err(error) = self.pty_read(&mut state, &mut buffer) {
                                        eprintln!("kero: Alacritty PTY read failed: {error}");
                                        break 'event_loop;
                                    }
                                }
                                if event.writable {
                                    if let Err(error) = self.pty_write(&mut state) {
                                        eprintln!("kero: Alacritty PTY write failed: {error}");
                                        break 'event_loop;
                                    }
                                }
                            }
                            _ => {}
                        }
                    }

                    let needs_write = state.needs_write();
                    if needs_write != interest.writable {
                        interest.writable = needs_write;
                        if let Err(error) = self.pty.reregister(&self.poller, interest, poll_mode) {
                            eprintln!("kero: Alacritty PTY registration update failed: {error}");
                            break;
                        }
                    }
                }
                let _ = self.pty.deregister(&self.poller);
            })
            .expect("spawn Kero Alacritty PTY event loop")
    }
}

struct Writing {
    source: Cow<'static, [u8]>,
    written: usize,
}

impl Writing {
    fn new(source: Cow<'static, [u8]>) -> Self {
        Self { source, written: 0 }
    }

    fn advance(&mut self, count: usize) {
        self.written += count;
    }

    fn remaining_bytes(&self) -> &[u8] {
        &self.source[self.written..]
    }

    fn finished(&self) -> bool {
        self.written >= self.source.len()
    }
}

#[derive(Clone)]
pub(crate) struct GraphicsEventLoopSender {
    sender: Sender<GraphicsMsg>,
    poller: Arc<Poller>,
}

impl GraphicsEventLoopSender {
    pub(crate) fn send(&self, message: GraphicsMsg) -> io::Result<()> {
        self.sender
            .send(message)
            .map_err(|error| io::Error::new(ErrorKind::BrokenPipe, error.to_string()))?;
        self.poller.notify()
    }
}

pub(crate) struct GraphicsNotifier(pub(crate) GraphicsEventLoopSender);

impl Notify for GraphicsNotifier {
    fn notify<B>(&self, bytes: B)
    where
        B: Into<Cow<'static, [u8]>>,
    {
        let bytes = bytes.into();
        if !bytes.is_empty() {
            let _ = self.0.send(GraphicsMsg::Input(bytes));
        }
    }
}

impl OnResize for GraphicsNotifier {
    fn on_resize(&mut self, size: WindowSize) {
        let _ = self.0.send(GraphicsMsg::Resize(size));
    }
}

#[derive(Default)]
struct GraphicsEventLoopState {
    write_list: VecDeque<Cow<'static, [u8]>>,
    writing: Option<Writing>,
    parser: ansi::Processor,
    graphics_interceptor: KittyGraphicsInterceptor,
    graphics_cursor_tracker: KittyGraphicsCursorTracker,
}

impl GraphicsEventLoopState {
    fn ensure_next(&mut self) {
        if self.writing.is_none() {
            self.goto_next();
        }
    }

    fn goto_next(&mut self) {
        self.writing = self.write_list.pop_front().map(Writing::new);
    }

    fn take_current(&mut self) -> Option<Writing> {
        self.writing.take()
    }

    fn set_current(&mut self, current: Option<Writing>) {
        self.writing = current;
    }

    fn needs_write(&self) -> bool {
        self.writing.is_some() || !self.write_list.is_empty()
    }
}

struct PeekableReceiver<T> {
    receiver: Receiver<T>,
    peeked: Option<T>,
}

impl<T> PeekableReceiver<T> {
    fn new(receiver: Receiver<T>) -> Self {
        Self {
            receiver,
            peeked: None,
        }
    }

    fn peek(&mut self) -> Option<&T> {
        if self.peeked.is_none() {
            self.peeked = self.receiver.try_recv().ok();
        }
        self.peeked.as_ref()
    }

    fn recv(&mut self) -> Option<T> {
        if self.peeked.is_some() {
            self.peeked.take()
        } else {
            match self.receiver.try_recv() {
                Err(TryRecvError::Disconnected) => None,
                result => result.ok(),
            }
        }
    }
}
