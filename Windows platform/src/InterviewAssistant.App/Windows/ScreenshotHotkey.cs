using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;

namespace InterviewAssistant.Windows;

/// <summary>
/// The global screenshot hotkey. It lives on its own message-only window, so hiding the main window or
/// re-creating its handle during an interview cannot drop it, and it is only held while a prompt board
/// is open, so the shortcut (Ctrl+Shift+S by default, "Save As" in many apps) belongs to other apps the
/// rest of the time.
/// </summary>
internal static class ScreenshotHotkey
{
    private const int HotkeyId = 0x4941;
    private const int ProbeId = 0x4942;
    private static HwndSource? _source;
    private static string? _registered;

    /// <summary>Raised on the UI thread when the hotkey is pressed.</summary>
    internal static event Action? Pressed;

    internal static bool IsRegistered => _registered is not null;

    /// <summary>Registers <paramref name="text"/>. Returns false when another application owns it.</summary>
    internal static bool Register(string text)
    {
        if (_registered is not null && string.Equals(_registered, text, StringComparison.OrdinalIgnoreCase)) return true;
        Unregister();
        if (!TryParse(text, out var modifiers, out var virtualKey)) return false;
        if (!NativeMethods.RegisterHotKey(EnsureWindow(), HotkeyId, modifiers, virtualKey)) return false;
        _registered = text;
        return true;
    }

    internal static void Unregister()
    {
        if (_source is not null && _registered is not null) _ = NativeMethods.UnregisterHotKey(_source.Handle, HotkeyId);
        _registered = null;
    }

    /// <summary>True when <paramref name="text"/> is a valid combination that no other application has taken.</summary>
    internal static bool IsAvailable(string text)
    {
        if (!TryParse(text, out var modifiers, out var virtualKey)) return false;
        if (_registered is not null && string.Equals(_registered, text, StringComparison.OrdinalIgnoreCase)) return true;
        var handle = EnsureWindow();
        if (!NativeMethods.RegisterHotKey(handle, ProbeId, modifiers, virtualKey))
        {
            // Our own active registration of the same keys also reports "already registered".
            return Marshal.GetLastWin32Error() == NativeMethods.ErrorHotkeyAlreadyRegistered
                && _registered is not null
                && TryParse(_registered, out var ownModifiers, out var ownKey)
                && ownModifiers == modifiers && ownKey == virtualKey;
        }
        _ = NativeMethods.UnregisterHotKey(handle, ProbeId);
        return true;
    }

    internal static bool TryParse(string text, out uint modifiers, out uint virtualKey)
    {
        modifiers = 0;
        virtualKey = 0;
        Key? key = null;
        foreach (var part in (text ?? "").Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            if (part.Equals("Ctrl", StringComparison.OrdinalIgnoreCase) || part.Equals("Control", StringComparison.OrdinalIgnoreCase)) modifiers |= NativeMethods.ModControl;
            else if (part.Equals("Shift", StringComparison.OrdinalIgnoreCase)) modifiers |= NativeMethods.ModShift;
            else if (part.Equals("Alt", StringComparison.OrdinalIgnoreCase)) modifiers |= NativeMethods.ModAlt;
            else if (part.Equals("Win", StringComparison.OrdinalIgnoreCase) || part.Equals("Windows", StringComparison.OrdinalIgnoreCase)) modifiers |= NativeMethods.ModWin;
            else if (Enum.TryParse<Key>(part, true, out var parsed)) key = parsed;
            else return false;
        }
        if (key is null || modifiers == 0) return false;
        virtualKey = (uint)KeyInterop.VirtualKeyFromKey(key.Value);
        if (virtualKey == 0) return false;
        modifiers |= NativeMethods.ModNoRepeat;
        return true;
    }

    private static nint EnsureWindow()
    {
        if (_source is not null) return _source.Handle;
        var parameters = new HwndSourceParameters("InterviewAssistantHotkeys")
        {
            ParentWindow = new nint(-3), // HWND_MESSAGE: message-only, never shown.
            Width = 0,
            Height = 0,
            WindowStyle = 0,
        };
        _source = new HwndSource(parameters);
        _source.AddHook(Hook);
        return _source.Handle;
    }

    private static nint Hook(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == NativeMethods.WmHotkey && wParam.ToInt32() == HotkeyId)
        {
            handled = true;
            Pressed?.Invoke();
        }
        return nint.Zero;
    }
}
