using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

public enum DialogTone { Info, Success, Warning, Danger, Update }

/// <summary>
/// Small rounded, theme-aware dialog (the Windows counterpart of the macOS .alert):
/// title, message, optional text field and up to two buttons.
/// </summary>
public sealed class AppDialog : Window
{
    private readonly TextBox? _input;

    private AppDialog(string title, string message, DialogTone tone, string primary, string? secondary, string? inputText, bool destructive)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        SizeToContent = SizeToContent.Height;
        Width = 440;
        FontFamily = new FontFamily("Segoe UI Variable Text, SimSun, Segoe UI");
        SetResourceReference(ForegroundProperty, "TextPrimaryBrush");
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var (glyph, brushKey) = tone switch
        {
            DialogTone.Success => ("", "SuccessBrush"),
            DialogTone.Warning => ("", "WarningBrush"),
            DialogTone.Danger => ("", "DangerBrush"),
            DialogTone.Update => ("", "PrimaryBrush"),
            _ => ("", "PrimaryBrush")
        };

        var icon = new Border
        {
            Width = 46,
            Height = 46,
            CornerRadius = new CornerRadius(14),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = new TextBlock
            {
                Text = glyph,
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 21,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        ((TextBlock)icon.Child).SetResourceReference(TextBlock.ForegroundProperty, brushKey);
        icon.SetResourceReference(Border.BackgroundProperty, "InputBrush");

        var stack = new StackPanel();
        stack.Children.Add(icon);
        stack.Children.Add(new TextBlock { Text = title, FontSize = 19, FontWeight = FontWeights.Bold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 16, 0, 0) });
        if (!string.IsNullOrWhiteSpace(message))
        {
            var body = new TextBlock { Text = message, FontSize = 14, LineHeight = 22, TextWrapping = TextWrapping.Wrap };
            body.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
            stack.Children.Add(new ScrollViewer
            {
                Content = body,
                MaxHeight = 320,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Margin = new Thickness(0, 8, 0, 0)
            });
        }
        if (inputText is not null)
        {
            _input = new TextBox { Text = inputText, Margin = new Thickness(0, 16, 0, 0) };
            _input.SetResourceReference(StyleProperty, "InputStyle");
            _input.KeyDown += (_, e) => { if (e.Key == Key.Enter) Finish(true); };
            stack.Children.Add(_input);
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 22, 0, 0) };
        if (secondary is not null)
        {
            var cancel = new Button { Content = secondary, Margin = new Thickness(0, 0, 10, 0), IsCancel = true };
            cancel.SetResourceReference(StyleProperty, "SecondaryButtonStyle");
            cancel.Click += (_, _) => Finish(false);
            buttons.Children.Add(cancel);
        }
        var ok = new Button { Content = primary, IsDefault = inputText is null };
        ok.SetResourceReference(StyleProperty, "PrimaryButtonStyle");
        if (destructive) ok.SetResourceReference(BackgroundProperty, "DangerBrush");
        ok.Click += (_, _) => Finish(true);
        buttons.Children.Add(ok);
        stack.Children.Add(buttons);

        var card = new Border
        {
            CornerRadius = new CornerRadius(22),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(26, 24, 26, 22),
            Margin = new Thickness(18),
            Child = stack,
            Effect = new DropShadowEffect { BlurRadius = 30, ShadowDepth = 8, Direction = 270, Opacity = 0.22, Color = Color.FromRgb(0x1E, 0x29, 0x3B) }
        };
        card.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "BorderBrush");
        card.MouseLeftButtonDown += (_, e) => { if (e.ChangedButton == MouseButton.Left && e.OriginalSource is not TextBox) DragMove(); };
        Content = card;

        KeyDown += (_, e) => { if (e.Key == Key.Escape) Finish(false); };
        Loaded += (_, _) =>
        {
            card.RenderTransformOrigin = new Point(0.5, 0.5);
            var scale = new ScaleTransform(0.96, 0.96);
            card.RenderTransform = scale;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.96, 1, TimeSpan.FromMilliseconds(160)) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.96, 1, TimeSpan.FromMilliseconds(160)) { EasingFunction = ease });
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)));
            if (_input is not null) { _input.Focus(); _input.SelectAll(); }
        };
    }

    private bool _result;

    private void Finish(bool result)
    {
        _result = result;
        Close();
    }

    private static Window? ResolveOwner(Window? owner) =>
        owner ?? Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive) ?? Application.Current?.MainWindow;

    /// <summary>Shows a message. Returns true when the primary button is pressed.</summary>
    public static bool Show(Window? owner, string title, string message, DialogTone tone = DialogTone.Info, string? primary = null, string? secondary = null, bool destructive = false)
    {
        var dialog = new AppDialog(title, message, tone, primary ?? LocalizationManager.Text("OK"), secondary, null, destructive);
        var resolved = ResolveOwner(owner);
        if (resolved is not null && !ReferenceEquals(resolved, dialog)) dialog.Owner = resolved;
        dialog.ShowDialog();
        return dialog._result;
    }

    /// <summary>Asks for a line of text. Returns null when cancelled.</summary>
    public static string? Prompt(Window? owner, string title, string message, string initialText, string? primary = null)
    {
        var dialog = new AppDialog(title, message, DialogTone.Info, primary ?? LocalizationManager.Text("Save"), LocalizationManager.Text("Cancel"), initialText, false);
        var resolved = ResolveOwner(owner);
        if (resolved is not null) dialog.Owner = resolved;
        dialog.ShowDialog();
        return dialog._result ? dialog._input?.Text ?? "" : null;
    }
}
