using System.Windows;
using System.Windows.Input;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

public partial class MockInterviewOptionsWindow : Window
{
    private bool _normalizingCount;

    public MockInterviewOptionsWindow()
    {
        InitializeComponent();
        if (!LocalizationManager.Instance.IsChinese)
        {
            TitleText.Text = "Mock Interview Options";
            DescriptionText.Text = "Choose how many questions this mock interview should include.";
            UnitText.Text = "questions";
            RangeText.Text = "3–10";
            CancelButton.Content = "Cancel";
            StartButton.Content = "▶  Start Mock Interview";
        }
    }

    public int QuestionCount { get; private set; } = 6;

    private void Adjust(int delta) => SetCount(ParseCount() + delta);

    private int ParseCount() => int.TryParse(CountBox.Text.Trim(), out var value)
        ? Math.Clamp(value, 3, 10)
        : QuestionCount;

    private void SetCount(int value)
    {
        QuestionCount = Math.Clamp(value, 3, 10);
        _normalizingCount = true;
        CountBox.Text = QuestionCount.ToString();
        CountBox.CaretIndex = CountBox.Text.Length;
        _normalizingCount = false;
    }

    private void CountBox_PreviewTextInput(object sender, TextCompositionEventArgs e) =>
        e.Handled = e.Text.Any(character => !char.IsDigit(character));

    private void CountBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            SetCount(ParseCount());
            e.Handled = true;
        }
    }

    private void CountBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (_normalizingCount) return;
        if (int.TryParse(CountBox.Text, out var value) && value is >= 3 and <= 10) QuestionCount = value;
    }
    private void Decrease_Click(object sender, RoutedEventArgs e) => Adjust(-1);
    private void Increase_Click(object sender, RoutedEventArgs e) => Adjust(1);
    private void Start_Click(object sender, RoutedEventArgs e) { SetCount(ParseCount()); DialogResult = true; }
    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.ChangedButton == MouseButton.Left) DragMove(); }
}
