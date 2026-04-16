# Deep Display Feature Target

## Goal

Build a native macOS display control app inspired by SwitchResX.

The product should let a user:

- Inspect all connected displays.
- View and switch all available resolutions, including HiDPI/scaled modes when exposed or generated.
- View and switch refresh rates.
- View and switch available color format / range options when hardware and macOS expose them.
- Save and apply display presets.
- Control everything quickly from a menu bar app.

Very important product rule:

- The app may allow non-standard or risky display modes.
- Any risky mode change must support timed auto-revert if the mode does not work or the user does not confirm it.

This is a behavior clone target, not a branding clone. Do not reuse the SwitchResX name, icon, copy, or assets.

## Product Shape

- Native macOS app.
- Primary entry point is a menu bar extra.
- Secondary settings window for advanced configuration.
- Background agent/helper only when needed for features that cannot be done safely from the main app.

## Phase 1: MVP

### Core display discovery

- Detect all active displays.
- Show display name, identifier, connection state, bounds, and current mode.
- Refresh automatically when displays are added, removed, mirrored, or reconfigured.

### Mode listing

- List supported display modes per display.
- Group modes by resolution.
- Show width x height.
- Show refresh rate.
- Show HiDPI/scaled flag when detectable.
- Surface every exposed mode, not only a filtered "safe" subset.
- Distinguish standard, scaled, duplicated, low-resolution, and custom/non-standard modes where possible.
- Mark the current active mode.

### Mode switching

- Switch to an existing supported display mode.
- Switch refresh rate when multiple rates exist for the same resolution.
- Allow switching to non-standard modes behind warnings.
- Start a confirmation countdown after risky mode changes.
- Revert automatically to the last known working mode if the user does not confirm in time.
- Handle failure gracefully and restore the prior state when possible.

### Refresh rate selection

- Show all refresh rates available for the selected resolution.
- Let the user switch refresh rate directly from the menu bar.
- Preserve refresh rate preferences in presets.

### Color format and range

- Show available color transport / pixel format choices when detectable.
- Support options such as RGB and YCbCr where exposed by the system or helper layer.
- Show limited range vs full range when that data is available.
- Preserve color format / range preferences in presets when technically reliable.

### Menu bar UX

- One top-level menu bar item.
- Section per display.
- Fast actions for common resolutions and refresh rates.
- Clear current-selection checkmarks.
- Open settings window from the menu.

### Presets

- Save current multi-display state as a preset.
- Apply a preset later.
- Rename and delete presets.
- Persist presets locally.

### Settings window

- General settings page.
- Displays overview page.
- Presets management page.
- Advanced mode page.
- Launch at login toggle.
- Hotkey registration for opening the controller.
- Auto-revert timeout configuration for risky changes.

## Phase 2: Automation

- Per-application preset switching.
- Event-based actions when displays connect/disconnect.
- Time-based or manual quick actions.
- Optional AppleScript or Shortcuts integration.
- Configurable default behavior when the app launches.

## Phase 3: Advanced Controls

- Rotation and mirroring controls where macOS APIs allow it.
- Color profile shortcuts if safe and supported.
- Disable/enable display workflows if technically reliable.
- Advanced mode metadata view.
- Custom resolution workflow behind explicit warnings.
- Manual timing editor for advanced users.
- Import/export display sets and advanced presets.

## Future Roadmap: Full Parity Target

This section defines the long-term behavior target for near-full SwitchResX parity.

### Display Modes and HiDPI

- Enumerate every standard mode returned by the OS.
- Enumerate every scaled / HiDPI mode returned by the OS.
- Expose duplicate entries when the underlying timing differs, even if the resolution text matches.
- Provide filters to show all modes, safe modes only, HiDPI only, and custom modes.
- Support creating custom resolutions and custom HiDPI entries where technically possible.
- Track per-display limits and compatibility notes.

### Refresh Rate Control

- Show all rates for a resolution, including fractional rates such as 59.94 Hz and 23.98 Hz.
- Support preset pinning for preferred rate per display and per preset.
- Offer fallback order when a preferred rate is unavailable.

### Color Range and Pixel Encoding

- Expose RGB, YCbCr, full range, limited range, bit depth, and HDR/SDR variants where detectable.
- Show the currently active transport and bit depth in both menu and settings UI.
- Allow changing color range directly from the menu for supported displays.
- Persist and restore color options as part of presets and app-triggered automations.

### Custom Resolutions and Risky Operations

- Support creating, validating, enabling, disabling, and deleting custom resolutions.
- Support a testing flow before setting a custom resolution as default.
- Always show a confirmation dialog/countdown for risky mode changes.
- Always revert to the previous known-good state if the countdown expires.
- Keep a stored history of known-good display states for emergency recovery.
- Provide a "restore last working configuration" command in the menu bar app.

### Display Sets and Automation

- Save full multi-display states including resolution, rate, arrangement hints, rotation, mirroring, and color mode where possible.
- Apply display sets automatically on display connect/disconnect.
- Apply display sets when specific applications launch or become frontmost.
- Trigger scripts, AppleScript, or Shortcuts actions from display events.

### Menus and UX Parity

- Match the speed and density of a power-user display menu.
- Keep one-click access to current mode, alternative modes, rates, color options, and presets.
- Provide compact and expanded menu styles.
- Support per-display submenus and direct actions from the top-level menu.

### Daemon / Helper / Recovery

- Run a background agent to monitor display topology changes.
- Add a privileged helper only for features that require elevated operations.
- Isolate risky functionality behind clear warnings and recovery UX.
- Provide startup recovery if the previous session ended in an unstable display configuration.

### Scripting and Integration

- AppleScript support for querying displays, modes, presets, and applying configurations.
- Shortcuts support for applying presets and display states.
- URL scheme or CLI bridge for automation.

### Compatibility and Observability

- Maintain compatibility notes by macOS version, Intel vs Apple Silicon, and display vendor quirks.
- Log mode-switch attempts, failures, and reverts for diagnostics.
- Provide a user-visible debug panel for EDID, display mode metadata, and helper status.

## Non-Goals For MVP

- Perfect 1:1 parity with every SwitchResX feature.
- Kernel-level or unsupported hacks.
- Full parity for custom timing generation on day one.

## Technical Direction

- Language: Swift.
- UI: AppKit first.
- Architecture:
  - Menu bar app shell.
  - Display service layer wrapping CoreGraphics.
  - Persistence layer for presets and settings.
  - Hotkey manager.
  - Optional helper/daemon later if required.

## Candidate macOS APIs

- CoreGraphics display APIs for enumerating displays and modes.
- Reconfiguration callbacks for live display changes.
- ServiceManagement for launch-at-login / helper registration.
- AppKit for status item and settings UI.

## Data Model Targets

### Display

- Stable display ID.
- User-facing name.
- Current resolution.
- Current refresh rate.
- Current scaling / HiDPI marker.
- Current color format / range metadata when available.
- Available modes.

### DisplayMode

- Width.
- Height.
- Refresh rate.
- Pixel encoding / extra metadata if available.
- Bit depth if available.
- Dynamic range marker if available.
- Color range marker if available.
- Is current.
- Is HiDPI/scaled.
- Is custom/non-standard.

### Preset

- Preset ID.
- Name.
- Ordered list of target display configurations.
- Stored last-known-good fallback state.
- Created date.
- Updated date.

## UX Requirements

- Fast to open.
- Safe defaults.
- Never trap users in an unsupported mode without a recovery path.
- Always offer timed confirmation and auto-revert for risky changes.
- Make current mode obvious.
- Keep the common path to 1-2 clicks from the menu bar.

## Risks

- Some display capabilities vary by hardware and macOS version.
- External monitor features may depend on EDID/DDC behavior.
- Custom resolutions may require privileges or unsupported system changes.
- App Sandbox may block parts of the advanced feature set.
- Color range / pixel encoding controls may not be consistently exposed through public APIs.
- Some non-standard modes may appear selectable but still fail on apply.

## Suggested Build Order

1. Scaffold native AppKit menu bar app.
2. Implement display enumeration and live updates.
3. Implement full mode listing, including HiDPI/scaled metadata.
4. Implement mode switching with confirmation and timed auto-revert.
5. Implement refresh rate selection and persistence.
6. Implement color format / range inspection and switching where available.
7. Build menu bar sections for each display.
8. Add preset persistence and apply flow.
9. Add settings window, launch-at-login, and hotkeys.
10. Evaluate which advanced features need a helper.
11. Add custom resolution workflows and recovery tooling.

## Definition of Success For MVP

The app is successful when a user can install it, click the menu bar item, see each connected display, view all exposed resolutions including HiDPI/scaled variants, switch resolution and refresh rate, change color options where supported, and recover safely from a failed non-standard mode change without using System Settings.
