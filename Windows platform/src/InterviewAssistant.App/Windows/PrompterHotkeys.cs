using System.Windows.Interop;
using InterviewAssistant.Models;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

/// <summary>A prompter shortcut from Settings › Keyboard Shortcuts (macOS PrompterHotkey).</summary>
public enum PrompterShortcut
{
    ScrollUp,
    ScrollDown,
    AnswerNewQuestion,
    Screenshot,
    DeleteScreenshot,
    SubmitScreenshots
}

/// <summary>
/// The prompter's global shortcuts other than the screenshot one (which keeps its own lifecycle in
/// <see cref="ScreenshotHotkey"/>). Each is held only while it can act: scrolling while a prompt board is open,
/// “answer the new question” while that bar is shown, and delete / submit while screenshots are being collected.
/// The rest of the time the combinations stay with other applications.
/// </summary>
internal static class PrompterHotkeys
{
    private const int FirstId = 0x4950;
    private static HwndSource? _source;
    private static readonly Dictionary<PrompterShortcut, string> Registered = [];
    private static bool _boardOpen;
    private static bool _pendingQuestion;
    private static bool _screenshotSession;

    /// <summary>Raised on the UI thread when a shortcut is pressed.</summary>
    internal static event Action<PrompterShortcut>? Pressed;

    public static readonly PrompterShortcut[] All =
    [
        PrompterShortcut.ScrollUp, PrompterShortcut.ScrollDown, PrompterShortcut.AnswerNewQuestion,
        PrompterShortcut.Screenshot, PrompterShortcut.DeleteScreenshot, PrompterShortcut.SubmitScreenshots
    ];

    public static string DefaultKey(PrompterShortcut shortcut) => shortcut switch
    {
        PrompterShortcut.ScrollUp => "Ctrl+Up",
        PrompterShortcut.ScrollDown => "Ctrl+Down",
        PrompterShortcut.AnswerNewQuestion => "Ctrl+N",
        PrompterShortcut.Screenshot => "Ctrl+Shift+S",
        PrompterShortcut.DeleteScreenshot => "Ctrl+Back",
        _ => "Ctrl+Enter"
    };

    public static string CurrentKey(PrompterShortcut shortcut, AppPreferences preferences)
    {
        var value = shortcut switch
        {
            PrompterShortcut.ScrollUp => preferences.HotkeyScrollUp,
            PrompterShortcut.ScrollDown => preferences.HotkeyScrollDown,
            PrompterShortcut.AnswerNewQuestion => preferences.HotkeyAnswerNewQuestion,
            PrompterShortcut.Screenshot => preferences.ScreenshotHotkey,
            PrompterShortcut.DeleteScreenshot => preferences.HotkeyDeleteScreenshot,
            _ => preferences.HotkeySubmitScreenshots
        };
        return string.IsNullOrWhiteSpace(value) ? DefaultKey(shortcut) : value.Trim();
    }

    public static void SetKey(PrompterShortcut shortcut, AppPreferences preferences, string value)
    {
        switch (shortcut)
        {
            case PrompterShortcut.ScrollUp: preferences.HotkeyScrollUp = value; break;
            case PrompterShortcut.ScrollDown: preferences.HotkeyScrollDown = value; break;
            case PrompterShortcut.AnswerNewQuestion: preferences.HotkeyAnswerNewQuestion = value; break;
            case PrompterShortcut.Screenshot: preferences.ScreenshotHotkey = value; break;
            case PrompterShortcut.DeleteScreenshot: preferences.HotkeyDeleteScreenshot = value; break;
            default: preferences.HotkeySubmitScreenshots = value; break;
        }
    }

    /// <summary>“Ctrl+Shift+S” → “Ctrl + Shift + S”, “Ctrl+Up” → “Ctrl + ↑”, “Ctrl+Back” → “Ctrl + Backspace”.</summary>
    public static string Display(string key) => string.Join(" + ", key.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
        .Select(part => part.ToLowerInvariant() switch
        {
            "up" => "↑",
            "down" => "↓",
            "left" => "←",
            "right" => "→",
            "back" => "Backspace",
            "return" or "enter" => "Enter",
            "escape" => "Esc",
            _ => part.Length == 1 ? part.ToUpperInvariant() : part
        }));

    internal static void SetBoardOpen(bool value)
    {
        _boardOpen = value;
        if (!value)
        {
            _pendingQuestion = false;
            _screenshotSession = false;
        }
        Refresh();
    }

    internal static void SetPendingQuestion(bool value)
    {
        if (_pendingQuestion == value) return;
        _pendingQuestion = value;
        Refresh();
    }

    internal static void SetScreenshotSession(bool value)
    {
        if (_screenshotSession == value) return;
        _screenshotSession = value;
        Refresh();
    }

    /// <summary>Re-applies registrations, e.g. after a shortcut changed in Settings.</summary>
    internal static void Refresh()
    {
        var preferences = AppServices.Current.DataStore.Data.Preferences;
        foreach (var shortcut in All.Where(item => item != PrompterShortcut.Screenshot))
        {
            var active = shortcut switch
            {
                PrompterShortcut.AnswerNewQuestion => _boardOpen && _pendingQuestion,
                PrompterShortcut.DeleteScreenshot or PrompterShortcut.SubmitScreenshots => _boardOpen && _screenshotSession,
                _ => _boardOpen
            };
            var key = CurrentKey(shortcut, preferences);
            if (active && Registered.TryGetValue(shortcut, out var current) && string.Equals(current, key, StringComparison.OrdinalIgnoreCase)) continue;
            Unregister(shortcut);
            if (!active || !ScreenshotHotkey.TryParse(key, out var modifiers, out var virtualKey)) continue;
            if (NativeMethods.RegisterHotKey(EnsureWindow(), FirstId + (int)shortcut, modifiers, virtualKey)) Registered[shortcut] = key;
        }
    }

    /// <summary>True when <paramref name="key"/> is valid and no other application owns it (our own registrations count as free).</summary>
    internal static bool IsAvailable(string key)
    {
        if (!ScreenshotHotkey.TryParse(key, out var modifiers, out var virtualKey)) return false;
        if (Registered.Values.Any(value => string.Equals(value, key, StringComparison.OrdinalIgnoreCase))) return true;
        return ScreenshotHotkey.IsAvailable(key);
    }

    private static void Unregister(PrompterShortcut shortcut)
    {
        if (!Registered.Remove(shortcut) || _source is null) return;
        _ = NativeMethods.UnregisterHotKey(_source.Handle, FirstId + (int)shortcut);
    }

    private static nint EnsureWindow()
    {
        if (_source is not null) return _source.Handle;
        var parameters = new HwndSourceParameters("InterviewAssistantPrompterHotkeys")
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
        if (message != NativeMethods.WmHotkey) return nint.Zero;
        var index = wParam.ToInt32() - FirstId;
        if (index >= 0 && index < All.Length)
        {
            handled = true;
            Pressed?.Invoke((PrompterShortcut)index);
        }
        return nint.Zero;
    }
}
