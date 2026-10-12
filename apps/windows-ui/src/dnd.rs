//! Accepting files dragged out of Explorer.
//!
//! Slint cannot do this. Its `DropArea` only receives drags started by a `DragArea` inside the
//! same app, and the winit backend never maps winit's `DroppedFile`/`HoveredFile` events — still
//! true upstream — so a drop from Explorer reaches the window procedure and is thrown away. The
//! only way in is to register an OLE drop target on the HWND ourselves, which is what this module
//! does.
//!
//! The contract with the rest of the app: OLE callbacks arrive on the thread that registered the
//! target, which is the thread running Slint's event loop, and the handler still only touches the
//! channel. `upload_all` remains the single path into the console whether the file came from the
//! picker or from a drag — one set of rules about folder, expiry, sharing and refresh, no second
//! implementation free to drift.
//!
//! ## Why `IDropTarget` rather than `DragAcceptFiles`
//!
//! `DragAcceptFiles` + `WM_DROPFILES` is about a third of this code and needs no COM. It was
//! rejected because it reports a drop only after it happens: no `DragEnter`, no `DragOver`, so the
//! window cannot say "drop to upload to /Public" while you are still dragging, with the folder
//! named before you let go. That feedback is the difference between a drop target you discover and
//! one you trust.
//!
//! What the overlay does *not* do is refuse. An earlier version said "Sign in first" while signed
//! out, which is a message you cannot act on with a file in one hand and no free click — the drop
//! still had to land somewhere. So every file drag is accepted and `main` keeps the ones that got
//! there before a sign-in, shows the count on the sign-in card, and uploads them when it happens.

#![cfg(windows)]

use std::path::PathBuf;
use std::sync::mpsc::Sender;

use windows::core::Result;
// The `implement!` macro resolves `windows_core::` from this crate's own scope, so the name is the
// API here, not a style choice.
pub use windows_core::implement;
use windows::Win32::Foundation::{HWND, POINTL};
use windows::Win32::System::Com::{IDataObject, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL};
use windows::Win32::System::Ole::{
    IDropTarget, IDropTarget_Impl, DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE, CF_HDROP,
};
use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows::Win32::UI::Shell::{DragQueryFileW, HDROP};

use crate::Msg;

/// The drop target registered on the main window.
///
/// `main` parks the resulting `IDropTarget` in a thread-local for the life of the process: OLE
/// keeps a raw pointer to this implementation, so dropping it would leave the window calling into
/// freed memory on the next drag over it.
#[implement(IDropTarget)]
struct DropTarget {
    tx: Sender<Msg>,
}

/// The file list, if this drag carries one.
///
/// `CF_HDROP` is the shell's format: an `HDROP` handle in global memory. `0xFFFFFFFF` asks for the
/// count, then each index yields a path. Nothing here opens or copies the files — that happens on
/// the UI thread through the normal upload path.
fn paths_from(source: &IDataObject) -> Option<Vec<PathBuf>> {
    let fmt = FORMATETC {
        cfFormat: CF_HDROP.0,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
    };

    // Asking is not a commitment. A drag carrying text or a browser link answers DF_E_FORMATETC and
    // we report "not files", which the overlay turns into a plain non-accepting window.
    let mut medium = unsafe { source.GetData(&fmt) }.ok()?;

    let out = unsafe {
        let hdrop = HDROP(medium.u.hGlobal.0);
        if hdrop.0.is_null() {
            return None;
        }
        let count = DragQueryFileW(hdrop, 0xFFFF_FFFF, None);
        let mut files = Vec::with_capacity(count as usize);
        // 32 767 is the shell's own ceiling for a path; anything longer is not a path to act on.
        let mut buf = [0u16; 32_767];
        for i in 0..count {
            let len = DragQueryFileW(hdrop, i, Some(&mut buf));
            if len == 0 || len as usize >= buf.len() {
                continue;
            }
            files.push(PathBuf::from(String::from_utf16_lossy(&buf[..len as usize])));
        }
        // Explorer also reports directories, and a directory has no upload path. Dropping a folder
        // is common enough that it must not turn into a failed upload per file inside it.
        files.retain(|p| p.is_file());
        files
    };

    unsafe { windows::Win32::System::Ole::ReleaseStgMedium(&mut medium) };
    (!out.is_empty()).then_some(out)
}

/// Always copy.
///
/// A plain drag inside Explorer means *move*, and answering `DROPEFFECT_MOVE` tells the source it
/// may delete the original once the drop completes. DriveDrop uploads; it does not clear out
/// someone's Downloads folder. So the answer is copy whatever the modifiers say, and the overlay
/// says "Copied, not moved" so the promise is visible at the moment it is made.
fn effect(files: bool) -> DROPEFFECT {
    if files { DROPEFFECT_COPY } else { DROPEFFECT_NONE }
}

// Note the impl target: `#[implement]` generates a `DropTarget_Impl` type that carries the vtable,
// and the interface trait is implemented for *that*, not for `DropTarget`.
impl IDropTarget_Impl for DropTarget_Impl {
    fn DragEnter(
        &self,
        data_object: Option<&IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        _point: &POINTL,
        effect_out: *mut DROPEFFECT,
    ) -> Result<()> {
        let files = data_object.and_then(paths_from);
        let accepted = effect(files.is_some());
        if !effect_out.is_null() {
            unsafe { *effect_out = accepted };
        }
        // The overlay is a property of the window, and this callback cannot reach it — only the
        // channel, which the UI thread drains every 40 ms.
        let _ = self.tx.send(Msg::DropHover(accepted == DROPEFFECT_COPY));
        Ok(())
    }

    fn DragOver(
        &self,
        _keys: MODIFIERKEYS_FLAGS,
        _point: &POINTL,
        effect_out: *mut DROPEFFECT,
    ) -> Result<()> {
        // OLE hands no data object here, so the decision made on enter stands.
        if !effect_out.is_null() {
            unsafe { *effect_out = DROPEFFECT_COPY };
        }
        Ok(())
    }

    fn DragLeave(&self) -> Result<()> {
        let _ = self.tx.send(Msg::DropHover(false));
        Ok(())
    }

    fn Drop(
        &self,
        data_object: Option<&IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        _point: &POINTL,
        effect_out: *mut DROPEFFECT,
    ) -> Result<()> {
        let files = data_object.and_then(paths_from);
        if !effect_out.is_null() {
            unsafe { *effect_out = effect(files.is_some()) };
        }
        let _ = self.tx.send(Msg::DropHover(false));
        if let Some(files) = files {
            let _ = self.tx.send(Msg::Dropped(files));
        }
        Ok(())
    }
}

/// Register the target on `hwnd`. Keep the returned interface alive until the window is gone.
///
/// `OleInitialize` is attempted first and its answer ignored: winit initializes OLE on the
/// event-loop thread in most builds and calling it twice is harmless, but registering before
/// anything has initialized it fails with `CO_E_NOTINITIALIZED` and the window silently never
/// accepts drops — which looks exactly like this module not existing.
/// **The window already has a drop target when we get there: winit's.** winit implements
/// `IDropTarget` on Windows so it can emit `WindowEvent::DroppedFile`, and Slint's backend discards
/// those events — which is the whole reason this module exists. Registering a second target fails
/// with `0x80040101` ("this window has already been registered"), so the existing one is revoked
/// first and ours takes its place.
///
/// Nothing in this app uses Slint's in-app `DragArea`/`DropArea`, so taking the target off winit's
/// hands costs nothing here. It is worth knowing that this is a takeover, not an addition: any
/// future Slint drag-and-drop in this window would arrive at this module instead.
pub fn register(hwnd: HWND, tx: Sender<Msg>) -> Result<IDropTarget> {
    unsafe { windows::Win32::System::Ole::OleInitialize(None) }.ok();
    // Ignored on purpose: if nothing was registered, this is the error, and that is fine.
    unsafe { windows::Win32::System::Ole::RevokeDragDrop(hwnd) }.ok();
    let target: IDropTarget = DropTarget { tx }.into();
    unsafe { windows::Win32::System::Ole::RegisterDragDrop(hwnd, &target) }?;
    Ok(target)
}

// There is no matching `revoke`: the window is hidden to the tray rather than destroyed, so
// un-registering on close would break drops the next time it is shown, and the process has no
// shutdown hook to do it in. The thread-local in `main` keeps the target alive for the process, and
// OLE tears it down with the window.
