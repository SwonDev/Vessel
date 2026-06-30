## Problem

**Unity 6 games receive no mouse or keyboard input** under wine-dxmt on macOS. The window opens
and the cursor moves, but **all clicks and key presses are silently ignored** — menus can't be
used. Reproduced with *Ancient Kingdoms* (Steam AppID 2241380) and confirmed it's not game- or
launcher-specific.

## Root cause (confirmed from the game's `Player.log`)

```
<RI> Initializing input.
EnableMouseInPointer failed with the following error: Call not implemented.
Using Windows.Gaming.Input
```

Unity 6 calls `EnableMouseInPointer()` to switch to receiving `WM_POINTER` events instead of the
classic `WM_MOUSE` ones. Wine **stubs** this API (returns `ERROR_CALL_NOT_IMPLEMENTED`), so Unity
falls back to `Windows.Gaming.Input` and never gets usable mouse input. This affects **every**
Unity 6 title, and also Mythic/Whisky/CrossOver < 26.

References: WineHQ bug [#53847](https://bugs.winehq.org/show_bug.cgi?id=53847), forum thread
[t=42440](https://forum.winehq.org/viewtopic.php?t=42440), and Kron4ek's `EnableMouseInPointer.patch`
(this patch is adapted from it, ported to wine-9.x).

## Request

Would you consider including the `EnableMouseInPointer` implementation in the wine builds used by
DXMT? It's **win32u-only and additive** — it only does anything when a game has called
`EnableMouseInPointer()`, so it doesn't change behaviour for any other game. It implements the
`WM_LBUTTONDOWN/UP/MOUSEMOVE` → `WM_POINTERUPDATE` conversion that Unity 6 expects.

## Verification

- Compiles cleanly against `3Shain/wine` (tag `v9.9-mingw`, reports `wine-9.11`).
- The **whole engine builds and the core runs** (`wine64 --version`) with the patch — no ABI issues
  when the full tree is rebuilt (a standalone `win32u` swap into a prebuilt engine does mismatch,
  so it needs to be part of the build).
- Building 9.9 with current toolchains needed two unrelated workarounds (not part of this patch):
  `-std=gnu17` for the PE compiler (mingw GCC 16 treats `bool` as a C23 keyword), and stubbing
  `CGWindowListCreateImageFromArray` in `winemac.drv/cocoa_window.m` (removed in the macOS 15 SDK).

I maintain a macOS launcher ([Vessel](https://github.com/SwonDev)) and this is the last blocker for
Unity 6 titles. Happy to adjust the patch to your preferred style if you'd take it.

## Patch (`win32u`, adapted from Kron4ek's, ported to wine-9.x)

```diff
diff --git a/dlls/win32u/input.c b/dlls/win32u/input.c
index a582826..29479c1 100644
--- a/dlls/win32u/input.c
+++ b/dlls/win32u/input.c
@@ -2444,9 +2444,9 @@ void toggle_caret( HWND hwnd )
  */
 BOOL WINAPI NtUserEnableMouseInPointer( BOOL enable )
 {
-    FIXME( "enable %u stub!\n", enable );
-    RtlSetLastWin32Error( ERROR_CALL_NOT_IMPLEMENTED );
-    return FALSE;
+    struct ntuser_thread_info *thread_info = NtUserGetThreadInfo();
+    thread_info->mouse_in_pointer = (enable == TRUE);
+    return thread_info->mouse_in_pointer;
 }
 
 /**********************************************************************
@@ -2454,9 +2454,8 @@ BOOL WINAPI NtUserEnableMouseInPointer( BOOL enable )
  */
 BOOL WINAPI NtUserIsMouseInPointerEnabled(void)
 {
-    FIXME( "stub!\n" );
-    RtlSetLastWin32Error( ERROR_CALL_NOT_IMPLEMENTED );
-    return FALSE;
+    struct ntuser_thread_info *thread_info = NtUserGetThreadInfo();
+    return thread_info->mouse_in_pointer;
 }
 
 static BOOL is_captured_by_system(void)
diff --git a/dlls/win32u/message.c b/dlls/win32u/message.c
index b706241..89a4a18 100644
--- a/dlls/win32u/message.c
+++ b/dlls/win32u/message.c
@@ -4272,9 +4272,21 @@ BOOL WINAPI NtUserPostThreadMessage( DWORD thread, UINT msg, WPARAM wparam, LPAR
     return put_message_in_queue( &info, NULL );
 }
 
+static UINT vessel_pointer_button_pressed = 0;
+
 LRESULT WINAPI NtUserMessageCall( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam,
                                   void *result_info, DWORD type, BOOL ansi )
 {
+    if (type == NtUserGetDispatchParams && (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP || msg == WM_MOUSEMOVE)) {
+        struct ntuser_thread_info *ti_v = NtUserGetThreadInfo();
+        if (ti_v->mouse_in_pointer) {
+            if (msg == WM_LBUTTONDOWN) { wparam = MAKEWPARAM(1, POINTER_MESSAGE_FLAG_PRIMARY|POINTER_MESSAGE_FLAG_FIRSTBUTTON|POINTER_MESSAGE_FLAG_INCONTACT|POINTER_MESSAGE_FLAG_INRANGE); vessel_pointer_button_pressed = 1; }
+            else if (msg == WM_LBUTTONUP) { wparam = MAKEWPARAM(1, POINTER_MESSAGE_FLAG_PRIMARY|POINTER_MESSAGE_FLAG_INRANGE); vessel_pointer_button_pressed = 0; }
+            else { wparam = vessel_pointer_button_pressed ? MAKEWPARAM(1, POINTER_MESSAGE_FLAG_PRIMARY|POINTER_MESSAGE_FLAG_FIRSTBUTTON|POINTER_MESSAGE_FLAG_INCONTACT|POINTER_MESSAGE_FLAG_INRANGE) : MAKEWPARAM(1, POINTER_MESSAGE_FLAG_PRIMARY|POINTER_MESSAGE_FLAG_INRANGE); }
+            msg = WM_POINTERUPDATE;
+        }
+    }
+
     switch (type)
     {
     case NtUserScrollBarWndProc:
diff --git a/include/ntuser.h b/include/ntuser.h
index bd11567..18b9c68 100644
--- a/include/ntuser.h
+++ b/include/ntuser.h
@@ -87,6 +87,7 @@ struct ntuser_thread_info
     UINT           default_imc;       /* default input context */
     UINT64         client_imm;        /* client IMM thread info */
     UINT64         wmchar_data;       /* client data for WM_CHAR mappings */
+    BOOL           mouse_in_pointer;
 };
 
 static inline struct ntuser_thread_info *NtUserGetThreadInfo(void)
```
