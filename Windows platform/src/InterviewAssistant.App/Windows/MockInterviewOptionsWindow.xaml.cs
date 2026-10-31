using System.Windows;
using System.Windows.Input;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

public partial class MockInterviewOptionsWindow : Window
{
    private const int MinCount = 3;
    private const int MaxCount = 10;
    private const int DefaultCount = 6;
    private bool _normalizingCount;

    public MockInterviewOptionsWindow()
    {
        InitializeComponent();
        if (!LocalizationManager.Instance.IsChinese)
        {
            TitleText.Text = "Mock Interview Options";
            DescriptionText.Text = "Choose how many questions this mock interview should include.";
            UnitText.Text = "questions";
            CancelButton.Content = "Cancel";
            StartButton.Content = "▶  Start Mock Interview";
            CloseButton.ToolTip = "Close";
        }
        RangeText.Text = $"{MinCount}–{MaxCount}";
        SetCount(DefaultCount);
    }

    public int QuestionCount { get; private set; } = DefaultCount;

    /// <summary>Reads what the user typed. Empty / invalid input falls back to the last valid value.</summary>
    private int ParseCount() => int.TryParse(CountBox.Text.Trim(), out var value)
        ? Math.Clamp(value, MinCount, MaxCount)
        : QuestionCount;

    private void SetCount(int value)
    {
        QuestionCount = Math.Clamp(value, MinCount, MaxCount);
        _normalizingCount = true;
        CountBox.Text = QuestionCount.ToString();
        CountBox.CaretIndex = CountBox.Text.Length;
        _normalizingCount = false;
    }

    private void CountBox_PreviewTextInput(object sender, TextCompositionEventArgs e) =>
        e.Handled = e.Text.Any(character => !char.IsDigit(character));

    private void CountBox_Pasting(object sender, DataObjectPastingEventArgs e)
    {
        var text = e.DataObject.GetDataPresent(DataFormats.UnicodeText) ? e.DataObject.GetData(DataFormats.UnicodeText) as string : null;
        if (string.IsNullOrEmpty(text) || text.Any(character => !char.IsDigit(character))) e.CancelCommand();
    }

    private void CountBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Enter:
                SetCount(ParseCount());
                e.Handled = true;
                break;
            case Key.Up:
                SetCount(ParseCount() + 1);
                e.Handled = true;
                break;
            case Key.Down:
                SetCount(ParseCount() - 1);
                e.Handled = true;
                break;
        }
    }

    private void CountBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (_normalizingCount) return;
        // Accept the value as soon as it is in range, but do not rewrite the text while the
        // user is still typing (e.g. "1" on the way to "10").
        if (int.TryParse(CountBox.Text, out var value) && value is >= MinCount and <= MaxCount) QuestionCount = value;
    }

    private void CountBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) =>
        Dispatcher.BeginInvoke(new Action(CountBox.SelectAll));

    private void CountBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) => SetCount(ParseCount());

    private void Decrease_Click(object sender, RoutedEventArgs e) => SetCount(ParseCount() - 1);
    private void Increase_Click(object sender, RoutedEventArgs e) => SetCount(ParseCount() + 1);
    private void Start_Click(object sender, RoutedEventArgs e) { SetCount(ParseCount()); DialogResult = true; }
    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.ChangedButton == MouseButton.Left) DragMove(); }
}
