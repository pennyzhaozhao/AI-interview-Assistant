using InterviewAssistant.Infrastructure;
using InterviewAssistant.Services;

namespace InterviewAssistant.ViewModels;

public abstract class PageViewModel : ObservableObject
{
    private readonly string _titleKey;
    private readonly string _subtitleKey;

    protected PageViewModel(string title, string subtitle)
    {
        _titleKey = title;
        _subtitleKey = subtitle;
        LocalizationManager.Instance.LanguageChanged += () =>
        {
            OnPropertyChanged(nameof(Title));
            OnPropertyChanged(nameof(Subtitle));
        };
    }

    public string Title => LocalizationManager.Text(_titleKey);
    public string Subtitle => LocalizationManager.Text(_subtitleKey);
}
