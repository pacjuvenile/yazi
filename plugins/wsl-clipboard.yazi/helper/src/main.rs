#[cfg(not(windows))]
fn main() {
    eprintln!("wsl-clipboard-yazi helper is only useful on Windows");
    std::process::exit(1);
}

#[cfg(windows)]
mod app {
    use std::{
        env,
        error::Error,
        ffi::c_void,
        fs,
        io::{self, Read},
        mem, ptr, thread,
        time::Duration,
    };

    type Handle = *mut c_void;

    const CF_TEXT: u32 = 1;
    const CF_BITMAP: u32 = 2;
    const CF_HDROP: u32 = 15;
    const CF_UNICODETEXT: u32 = 13;
    const CF_DIB: u32 = 8;
    const CF_DIBV5: u32 = 17;
    const GMEM_MOVEABLE: u32 = 0x0002;
    const GMEM_ZEROINIT: u32 = 0x0040;
    const DROP_EFFECT_COPY: u32 = 1;
    const DROP_EFFECT_MOVE: u32 = 2;
    const DRAG_QUERY_FILE_COUNT: u32 = 0xFFFF_FFFF;
    const CLIPBOARD_OPEN_ATTEMPTS: usize = 60;
    const CLIPBOARD_WRITE_OPEN_ATTEMPTS: usize = 20;
    const CLIPBOARD_OPEN_DELAY_MS: u64 = 50;
    const CLIPBOARD_WRITE_OPEN_DELAY_MS: u64 = 25;
    const OWNER_FORMAT: &str = "wsl-clipboard.yazi.owner";
    const OWNER_MARKER: &[u8] = b"1";

    #[repr(C)]
    struct DropFiles {
        p_files: u32,
        pt_x: i32,
        pt_y: i32,
        f_nc: i32,
        f_wide: i32,
    }

    #[repr(C)]
    struct WndClassW {
        style: u32,
        lpfn_wnd_proc: Option<unsafe extern "system" fn(Handle, u32, usize, isize) -> isize>,
        cb_cls_extra: i32,
        cb_wnd_extra: i32,
        h_instance: Handle,
        h_icon: Handle,
        h_cursor: Handle,
        hbr_background: Handle,
        lpsz_menu_name: *const u16,
        lpsz_class_name: *const u16,
    }

    const HWND_MESSAGE: isize = -3isize;

    #[link(name = "user32")]
    extern "system" {
        fn OpenClipboard(hwnd_new_owner: Handle) -> i32;
        fn CloseClipboard() -> i32;
        fn EmptyClipboard() -> i32;
        fn SetClipboardData(format: u32, mem: Handle) -> Handle;
        fn GetClipboardData(format: u32) -> Handle;
        fn IsClipboardFormatAvailable(format: u32) -> i32;
        fn RegisterClipboardFormatW(name: *const u16) -> u32;
        fn RegisterClassW(class: *const WndClassW) -> u16;
        fn GetOpenClipboardWindow() -> Handle;
        fn GetWindowThreadProcessId(hwnd: Handle, process_id: *mut u32) -> u32;
        fn CreateWindowExW(
            ex_style: u32,
            class_name: *const u16,
            window_name: *const u16,
            style: u32,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
            parent: Handle,
            menu: Handle,
            instance: Handle,
            param: *mut c_void,
        ) -> Handle;
        fn DestroyWindow(hwnd: Handle) -> i32;
        fn DefWindowProcW(hwnd: Handle, msg: u32, wparam: usize, lparam: isize) -> isize;
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetModuleHandleW(name: *const u16) -> Handle;
        fn GlobalAlloc(flags: u32, bytes: usize) -> Handle;
        fn GlobalFree(mem: Handle) -> Handle;
        fn GlobalLock(mem: Handle) -> *mut c_void;
        fn GlobalUnlock(mem: Handle) -> i32;
        fn GetLastError() -> u32;
    }

    #[link(name = "shell32")]
    extern "system" {
        fn DragQueryFileW(hdrop: Handle, file: u32, buf: *mut u16, cch: u32) -> u32;
    }

    type Result<T> = std::result::Result<T, Box<dyn Error>>;

    #[derive(Clone, Copy)]
    struct Trace {
        enabled: bool,
    }

    impl Trace {
        fn new(enabled: bool) -> Self {
            Self { enabled }
        }

        fn step(&self, message: &str) {
            if self.enabled {
                eprintln!("trace:{message}");
            }
        }
    }

    unsafe extern "system" fn wnd_proc(
        hwnd: Handle,
        msg: u32,
        wparam: usize,
        lparam: isize,
    ) -> isize {
        DefWindowProcW(hwnd, msg, wparam, lparam)
    }

    fn create_clipboard_window(trace: Trace) -> Result<Handle> {
        trace.step("create-window:start");
        let class_name = wide_null("wsl-clipboard-yazi-helper-window");
        let instance = unsafe { GetModuleHandleW(ptr::null()) };
        let class = WndClassW {
            style: 0,
            lpfn_wnd_proc: Some(wnd_proc),
            cb_cls_extra: 0,
            cb_wnd_extra: 0,
            h_instance: instance,
            h_icon: ptr::null_mut(),
            h_cursor: ptr::null_mut(),
            hbr_background: ptr::null_mut(),
            lpsz_menu_name: ptr::null(),
            lpsz_class_name: class_name.as_ptr(),
        };
        unsafe {
            trace.step("register-class:start");
            RegisterClassW(&class);
            trace.step("create-window:call");
            let hwnd = CreateWindowExW(
                0,
                class_name.as_ptr(),
                class_name.as_ptr(),
                0,
                0,
                0,
                0,
                0,
                HWND_MESSAGE as Handle,
                ptr::null_mut(),
                instance,
                ptr::null_mut(),
            );
            if hwnd.is_null() {
                return Err("failed to create clipboard owner window".into());
            }
            trace.step("create-window:ok");
            Ok(hwnd)
        }
    }

    struct Clipboard {
        hwnd: Handle,
        owns_window: bool,
    }

    impl Clipboard {
        fn open(trace: Trace) -> Result<Self> {
            let hwnd = create_clipboard_window(trace)?;
            Self::open_with_retries(
                trace,
                hwnd,
                true,
                CLIPBOARD_OPEN_ATTEMPTS,
                CLIPBOARD_OPEN_DELAY_MS,
            )
        }

        fn open_for_write(trace: Trace) -> Result<Self> {
            trace.step("open-clipboard-owner:null");
            Self::open_with_retries(
                trace,
                ptr::null_mut(),
                false,
                CLIPBOARD_WRITE_OPEN_ATTEMPTS,
                CLIPBOARD_WRITE_OPEN_DELAY_MS,
            )
        }

        fn open_with_retries(
            trace: Trace,
            hwnd: Handle,
            owns_window: bool,
            attempts: usize,
            delay_ms: u64,
        ) -> Result<Self> {
            let mut last_error = 0;
            for attempt in 1..=attempts {
                trace.step(&format!("open-clipboard:try:{attempt}"));
                let opened = unsafe { OpenClipboard(hwnd) };
                if opened != 0 {
                    trace.step("open-clipboard:ok");
                    return Ok(Self { hwnd, owns_window });
                }
                last_error = unsafe { GetLastError() };
                trace.step(&format!("open-clipboard:last-error:{last_error}"));
                if attempt < attempts {
                    thread::sleep(Duration::from_millis(delay_ms));
                }
            }
            let owner = open_clipboard_owner_description();
            if owns_window && !hwnd.is_null() {
                unsafe {
                    DestroyWindow(hwnd);
                }
            }
            Err(format!(
                "failed to open Windows clipboard after {attempts} retries; last_error={last_error}; {owner}"
            )
            .into())
        }
    }

    impl Drop for Clipboard {
        fn drop(&mut self) {
            unsafe {
                CloseClipboard();
                if self.owns_window && !self.hwnd.is_null() {
                    DestroyWindow(self.hwnd);
                }
            }
        }
    }

    struct GlobalMem {
        handle: Handle,
        owned: bool,
    }

    impl GlobalMem {
        fn new(size: usize) -> Result<Self> {
            let handle = unsafe { GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size) };
            if handle.is_null() {
                return Err("GlobalAlloc failed".into());
            }
            Ok(Self {
                handle,
                owned: true,
            })
        }

        fn handle(&self) -> Handle {
            self.handle
        }

        fn release_to_clipboard(mut self) {
            self.owned = false;
        }
    }

    impl Drop for GlobalMem {
        fn drop(&mut self) {
            if self.owned && !self.handle.is_null() {
                unsafe {
                    GlobalFree(self.handle);
                }
            }
        }
    }

    fn wide_null(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn registered_format(name: &str) -> u32 {
        let wide = wide_null(name);
        unsafe { RegisterClipboardFormatW(wide.as_ptr()) }
    }

    fn open_clipboard_owner_description() -> String {
        unsafe {
            let hwnd = GetOpenClipboardWindow();
            if hwnd.is_null() {
                return "open_clipboard_window=null".to_string();
            }
            let mut pid = 0u32;
            let thread_id = GetWindowThreadProcessId(hwnd, &mut pid as *mut u32);
            format!("open_clipboard_window={hwnd:p}; owner_pid={pid}; owner_thread_id={thread_id}")
        }
    }

    fn set_global_data(format: u32, bytes: &[u8]) -> Result<()> {
        let mem = GlobalMem::new(bytes.len())?;
        unsafe {
            let ptr = GlobalLock(mem.handle());
            if ptr.is_null() {
                return Err("GlobalLock failed".into());
            }
            ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, bytes.len());
            GlobalUnlock(mem.handle());
            if SetClipboardData(format, mem.handle()).is_null() {
                return Err("SetClipboardData failed".into());
            }
        }
        mem.release_to_clipboard();
        Ok(())
    }

    fn make_hdrop(paths: &[String]) -> Result<GlobalMem> {
        let mut wide_paths = Vec::<u16>::new();
        for path in paths {
            wide_paths.extend(path.encode_utf16());
            wide_paths.push(0);
        }
        wide_paths.push(0);

        let header_size = mem::size_of::<DropFiles>();
        let data_size = wide_paths.len() * mem::size_of::<u16>();
        let mem = GlobalMem::new(header_size + data_size)?;

        unsafe {
            let ptr = GlobalLock(mem.handle());
            if ptr.is_null() {
                return Err("GlobalLock failed".into());
            }
            let header = ptr as *mut DropFiles;
            (*header).p_files = header_size as u32;
            (*header).pt_x = 0;
            (*header).pt_y = 0;
            (*header).f_nc = 0;
            (*header).f_wide = 1;

            ptr::copy_nonoverlapping(
                wide_paths.as_ptr() as *const u8,
                (ptr as *mut u8).add(header_size),
                data_size,
            );
            GlobalUnlock(mem.handle());
        }

        Ok(mem)
    }

    fn parse_path_payload(data: Vec<u8>, source: &str) -> Result<Vec<String>> {
        let text = String::from_utf8(data)?;
        let paths = text
            .split('\0')
            .filter(|item| !item.is_empty())
            .map(str::to_string)
            .collect::<Vec<_>>();
        if paths.is_empty() {
            return Err(format!("no paths were provided in {source}").into());
        }
        Ok(paths)
    }

    fn base64_value(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    fn decode_base64(input: &str) -> Result<Vec<u8>> {
        let bytes = input.as_bytes();
        if bytes.is_empty() {
            return Err("empty --payload-base64 value".into());
        }
        if bytes.len() % 4 != 0 {
            return Err("--payload-base64 length must be a multiple of 4".into());
        }

        let chunk_count = bytes.len() / 4;
        let mut out = Vec::with_capacity(chunk_count * 3);
        for chunk_index in 0..chunk_count {
            let chunk = &bytes[chunk_index * 4..chunk_index * 4 + 4];
            let last = chunk_index + 1 == chunk_count;
            let mut values = [0u8; 4];
            let mut padding = 0usize;

            for (index, byte) in chunk.iter().copied().enumerate() {
                if byte == b'=' {
                    if index < 2 {
                        return Err("invalid --payload-base64 padding".into());
                    }
                    padding += 1;
                } else if padding > 0 {
                    return Err("invalid --payload-base64 padding order".into());
                } else if let Some(value) = base64_value(byte) {
                    values[index] = value;
                } else {
                    return Err(format!("invalid --payload-base64 byte: 0x{byte:02x}").into());
                }
            }

            if padding > 0 && !last {
                return Err("invalid --payload-base64 padding before final chunk".into());
            }
            if padding > 2 {
                return Err("invalid --payload-base64 padding length".into());
            }

            out.push((values[0] << 2) | (values[1] >> 4));
            if padding < 2 {
                out.push(((values[1] & 0x0f) << 4) | (values[2] >> 2));
            }
            if padding < 1 {
                out.push(((values[2] & 0x03) << 6) | values[3]);
            }
        }

        Ok(out)
    }

    fn read_base64_paths(payload: &str) -> Result<Vec<String>> {
        parse_path_payload(decode_base64(payload)?, "--payload-base64")
    }

    fn read_path_list(path: &str) -> Result<Vec<String>> {
        parse_path_payload(fs::read(path)?, "--path-list")
    }

    fn read_stdin_paths(len: usize) -> Result<Vec<String>> {
        let mut data = Vec::with_capacity(len);
        io::stdin().lock().take(len as u64).read_to_end(&mut data)?;
        if data.len() != len {
            return Err(format!(
                "stdin ended before declared payload length: expected {len} bytes, got {}",
                data.len()
            )
            .into());
        }
        parse_path_payload(data, "--stdin-len")
    }

    fn parse_paths(args: &[String]) -> Result<Vec<String>> {
        if let Some(index) = args.iter().position(|arg| arg == "--payload-base64") {
            let payload = args
                .get(index + 1)
                .ok_or("--payload-base64 requires a value")?;
            return read_base64_paths(payload);
        }

        if let Some(index) = args.iter().position(|arg| arg == "--stdin-len") {
            let len = args
                .get(index + 1)
                .ok_or("--stdin-len requires a byte length")?
                .parse::<usize>()?;
            return read_stdin_paths(len);
        }

        if let Some(index) = args.iter().position(|arg| arg == "--path-list") {
            let path = args
                .get(index + 1)
                .ok_or("--path-list requires a file path")?;
            return read_path_list(path);
        }

        let paths = args
            .iter()
            .filter(|arg| arg.as_str() != "--")
            .filter(|arg| arg.as_str() != "--copy")
            .filter(|arg| arg.as_str() != "--cut")
            .filter(|arg| arg.as_str() != "--stdin-len")
            .filter(|arg| arg.as_str() != "--payload-base64")
            .filter(|arg| !arg.is_empty())
            .cloned()
            .collect::<Vec<_>>();
        if paths.is_empty() {
            return Err("no paths were provided".into());
        }
        Ok(paths)
    }

    fn normalize_windows_path(path: &str) -> String {
        path.trim_end_matches(['\\', '/'])
            .replace('/', "\\")
            .to_lowercase()
    }

    fn same_path_set(left: &[String], right: &[String]) -> bool {
        if left.len() != right.len() {
            return false;
        }

        let mut counts = std::collections::HashMap::<String, usize>::new();
        for path in left {
            *counts.entry(normalize_windows_path(path)).or_insert(0) += 1;
        }
        for path in right {
            let key = normalize_windows_path(path);
            let Some(count) = counts.get_mut(&key) else {
                return false;
            };
            if *count == 1 {
                counts.remove(&key);
            } else {
                *count -= 1;
            }
        }
        counts.is_empty()
    }

    fn write_files(paths: &[String], cut: bool, trace: Trace) -> Result<()> {
        trace.step("write-files:start");
        let paths = parse_paths(paths)?;
        trace.step("write-files:open-clipboard");
        let _clipboard = Clipboard::open_for_write(trace)?;
        unsafe {
            trace.step("write-files:empty-clipboard");
            if EmptyClipboard() == 0 {
                return Err("EmptyClipboard failed".into());
            }
        }

        trace.step("write-files:make-hdrop");
        let hdrop = make_hdrop(&paths)?;
        unsafe {
            trace.step("write-files:set-cf-hdrop");
            if SetClipboardData(CF_HDROP, hdrop.handle()).is_null() {
                return Err("SetClipboardData(CF_HDROP) failed".into());
            }
        }
        hdrop.release_to_clipboard();

        let effect = if cut {
            DROP_EFFECT_MOVE
        } else {
            DROP_EFFECT_COPY
        };
        let effect_format = registered_format("Preferred DropEffect");
        if effect_format == 0 {
            return Err("RegisterClipboardFormat(Preferred DropEffect) failed".into());
        }
        trace.step("write-files:set-drop-effect");
        set_global_data(effect_format, &effect.to_le_bytes())?;

        let owner_format = registered_format(OWNER_FORMAT);
        if owner_format != 0 {
            trace.step("write-files:set-owner-marker");
            if let Err(err) = set_global_data(owner_format, OWNER_MARKER) {
                trace.step(&format!("write-files:set-owner-marker-failed:{err}"));
            }
        }
        trace.step("write-files:ok");
        Ok(())
    }

    fn clear(trace: Trace) -> Result<()> {
        trace.step("clear:start");
        let _clipboard = Clipboard::open_for_write(trace)?;
        unsafe {
            trace.step("clear:empty-clipboard");
            if EmptyClipboard() == 0 {
                return Err("EmptyClipboard failed".into());
            }
        }
        trace.step("clear:ok");
        Ok(())
    }

    fn clear_owned(paths: &[String], cut: bool, trace: Trace) -> Result<()> {
        trace.step("clear-owned:start");
        let expected_paths = parse_paths(paths)?;
        let _clipboard = Clipboard::open_for_write(trace)?;

        if !has_owner_marker() {
            trace.step("clear-owned:skip:not-owner");
            println!("skipped:not-owner");
            return Ok(());
        }

        let effect = read_drop_effect();
        if (effect == "move") != cut {
            trace.step("clear-owned:skip:effect-mismatch");
            println!("skipped:effect-mismatch");
            return Ok(());
        }

        let Some(current_paths) = read_file_drop()? else {
            trace.step("clear-owned:skip:no-files");
            println!("skipped:no-files");
            return Ok(());
        };
        if !same_path_set(&expected_paths, &current_paths) {
            trace.step("clear-owned:skip:path-mismatch");
            println!("skipped:path-mismatch");
            return Ok(());
        }

        unsafe {
            trace.step("clear-owned:empty-clipboard");
            if EmptyClipboard() == 0 {
                return Err("EmptyClipboard failed".into());
            }
        }
        trace.step("clear-owned:ok");
        println!("cleared");
        Ok(())
    }

    fn diagnose(trace: Trace) -> Result<()> {
        trace.step("diagnose:start");
        println!("version={}", env!("CARGO_PKG_VERSION"));
        println!("process=started");
        let _clipboard = Clipboard::open_for_write(trace)?;
        println!("open_clipboard=ok");
        println!("diagnose=ok");
        trace.step("diagnose:ok");
        Ok(())
    }

    fn is_format_available(format: u32) -> bool {
        unsafe { IsClipboardFormatAvailable(format) != 0 }
    }

    fn read_drop_effect() -> &'static str {
        let format = registered_format("Preferred DropEffect");
        if format == 0 || !is_format_available(format) {
            return "copy";
        }

        unsafe {
            let handle = GetClipboardData(format);
            if handle.is_null() {
                return "copy";
            }
            let ptr = GlobalLock(handle);
            if ptr.is_null() {
                return "copy";
            }
            let mut bytes = [0u8; 4];
            ptr::copy_nonoverlapping(ptr as *const u8, bytes.as_mut_ptr(), bytes.len());
            GlobalUnlock(handle);
            if u32::from_le_bytes(bytes) == DROP_EFFECT_MOVE {
                "move"
            } else {
                "copy"
            }
        }
    }

    fn has_owner_marker() -> bool {
        let format = registered_format(OWNER_FORMAT);
        format != 0 && is_format_available(format)
    }

    fn read_file_drop() -> Result<Option<Vec<String>>> {
        if !is_format_available(CF_HDROP) {
            return Ok(None);
        }

        let handle = unsafe { GetClipboardData(CF_HDROP) };
        if handle.is_null() {
            return Ok(None);
        }

        let count = unsafe { DragQueryFileW(handle, DRAG_QUERY_FILE_COUNT, ptr::null_mut(), 0) };
        if count == 0 {
            return Ok(None);
        }

        let mut paths = Vec::with_capacity(count as usize);
        for i in 0..count {
            let len = unsafe { DragQueryFileW(handle, i, ptr::null_mut(), 0) };
            if len == 0 {
                continue;
            }
            let mut buf = vec![0u16; len as usize + 1];
            let written = unsafe { DragQueryFileW(handle, i, buf.as_mut_ptr(), buf.len() as u32) };
            if written == 0 {
                continue;
            }
            buf.truncate(written as usize);
            paths.push(String::from_utf16_lossy(&buf));
        }

        Ok((!paths.is_empty()).then_some(paths))
    }

    fn image_ext() -> Option<&'static str> {
        let png = registered_format("PNG");
        if png != 0 && is_format_available(png) {
            return Some("png");
        }
        let jfif = registered_format("JFIF");
        if jfif != 0 && is_format_available(jfif) {
            return Some("jpg");
        }
        let gif = registered_format("GIF");
        if gif != 0 && is_format_available(gif) {
            return Some("gif");
        }
        let tiff = registered_format("TIFF");
        if tiff != 0 && is_format_available(tiff) {
            return Some("tiff");
        }
        if is_format_available(CF_DIBV5)
            || is_format_available(CF_DIB)
            || is_format_available(CF_BITMAP)
        {
            return Some("bmp");
        }
        None
    }

    fn read_paste(trace: Trace) -> Result<()> {
        trace.step("read-paste:start");
        let _clipboard = Clipboard::open(trace)?;
        if let Some(paths) = read_file_drop()? {
            trace.step("read-paste:files");
            println!("__kind__:files");
            println!("__effect__:{}", read_drop_effect());
            if has_owner_marker() {
                println!("__owner__:wsl-clipboard.yazi");
            }
            for path in paths {
                println!("{path}");
            }
            return Ok(());
        }
        if let Some(ext) = image_ext() {
            trace.step("read-paste:image");
            println!("__kind__:image");
            println!("{ext}");
            return Ok(());
        }
        let html = registered_format("HTML Format");
        if html != 0 && is_format_available(html) {
            trace.step("read-paste:html");
            println!("__kind__:html");
            return Ok(());
        }
        if is_format_available(CF_UNICODETEXT) || is_format_available(CF_TEXT) {
            trace.step("read-paste:text");
            println!("__kind__:text");
        }
        trace.step("read-paste:ok");
        Ok(())
    }

    fn probe_image(trace: Trace) -> Result<()> {
        trace.step("probe-image:start");
        let _clipboard = Clipboard::open(trace)?;
        if let Some(ext) = image_ext() {
            println!("{ext}");
        }
        trace.step("probe-image:ok");
        Ok(())
    }

    fn print_help() {
        eprintln!(
            "usage: wsl-clipboard-yazi [--trace] <write-files --copy|--cut (-- <path...>|--path-list <file>|--stdin-len <bytes>|--payload-base64 <payload>)|clear-owned --copy|--cut (-- <path...>|--path-list <file>|--stdin-len <bytes>|--payload-base64 <payload>)|clear|read-paste|probe-image|diagnose|version>"
        );
    }

    pub fn main() -> Result<()> {
        let mut args = env::args().skip(1).collect::<Vec<_>>();
        let trace = Trace::new(args.iter().any(|arg| arg == "--trace"));
        trace.step("process:start");
        args.retain(|arg| arg != "--trace");
        if args.is_empty() {
            print_help();
            return Err("missing command".into());
        }

        let command = args.remove(0);
        trace.step(&format!("command:{command}"));
        match command.as_str() {
            "write-files" => {
                let cut = args.iter().any(|arg| arg == "--cut");
                write_files(&args, cut, trace)
            }
            "clear-owned" => {
                let cut = args.iter().any(|arg| arg == "--cut");
                clear_owned(&args, cut, trace)
            }
            "clear" => clear(trace),
            "read-paste" => read_paste(trace),
            "probe-image" => probe_image(trace),
            "diagnose" => diagnose(trace),
            "version" => {
                println!("{}", env!("CARGO_PKG_VERSION"));
                Ok(())
            }
            _ => {
                print_help();
                Err("unknown command".into())
            }
        }
    }
}

#[cfg(windows)]
fn main() {
    if let Err(err) = app::main() {
        eprintln!("{err}");
        std::process::exit(1);
    }
}
