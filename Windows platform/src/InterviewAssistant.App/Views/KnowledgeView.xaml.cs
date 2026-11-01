using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using InterviewAssistant.Models;
using InterviewAssistant.Services;
using InterviewAssistant.ViewModels;

namespace InterviewAssistant.Views;

public partial class KnowledgeView : UserControl
{
    private const string ResumeFilter = "Resume|*.pdf;*.docx;*.doc;*.rtf;*.txt;*.md|All files|*.*";

    public KnowledgeView() => InitializeComponent();

    private KnowledgeViewModel? Page => DataContext as KnowledgeViewModel;
    private KnowledgeBaseItemViewModel? Current => Page?.SelectedKnowledgeBase;
    private Window? Owner => Window.GetWindow(this);

    private void KnowledgeList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (DataContext is not KnowledgeViewModel { IsSelectionMode: true }) return;
        if (FindAncestor<Button>(e.OriginalSource as DependencyObject) is not null) return;
        var container = FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject);
        if (container?.DataContext is not KnowledgeBaseItemViewModel item) return;
        item.IsBulkSelected = !item.IsBulkSelected;
        e.Handled = true;
    }

    private static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
    {
        while (current is not null && current is not T)
            current = current is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(current) : LogicalTreeHelper.GetParent(current);
        return current as T;
    }

    // ───────────── resume ─────────────

    private async void UploadResume_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { } kb || kb.IsResumeBusy) return;
        var dialog = new OpenFileDialog { Title = LocalizationManager.Text("Upload resume (PDF / Word)"), Filter = ResumeFilter };
        if (dialog.ShowDialog(Owner) != true) return;
        await ImportResumeAsync(kb, dialog.FileName);
    }

    private async void ResumeDrop_Drop(object sender, DragEventArgs e)
    {
        if (Current is not { } kb || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files) await ImportResumeAsync(kb, files[0]);
    }

    private async Task ImportResumeAsync(KnowledgeBaseItemViewModel kb, string path)
    {
        if (kb.HasResume && !Windows.AppDialog.Show(Owner, LocalizationManager.Text("Replace resume?"),
                LocalizationManager.Text("ReplaceResumeMessage"), Windows.DialogTone.Warning,
                LocalizationManager.Text("Replace"), LocalizationManager.Text("Cancel")))
            return;
        if (ChooseResumeProcessing() is not { } useAI) return;
        await kb.ImportResumeAsync(path, useAI);
    }

    /// <summary>
    /// AI or original-only for an uploaded resume: asks unless the user chose "remember".
    /// Without an AI provider the original is saved directly. Returns null when the dialog is dismissed.
    /// </summary>
    private bool? ChooseResumeProcessing()
    {
        if (!KnowledgeAssistant.IsAIConfigured()) return false;
        var preferences = AppServices.Current.DataStore.Data.Preferences;
        if (preferences.ResumeAIProcessing == ResumeAIModes.AI) return true;
        if (preferences.ResumeAIProcessing == ResumeAIModes.Raw) return false;
        var choice = Windows.AppDialog.Choose(Owner,
            LocalizationManager.Text("Organize this resume with AI?"),
            LocalizationManager.Text("ResumeAIChoiceMessage"),
            LocalizationManager.Text("Organize with AI"),
            LocalizationManager.Text("Save original only"),
            LocalizationManager.Text("Remember my choice (change it in Settings)"),
            out var remember);
        if (choice is { } useAI && remember)
        {
            preferences.ResumeAIProcessing = useAI ? ResumeAIModes.AI : ResumeAIModes.Raw;
            AppServices.Current.DataStore.ScheduleSave();
            ResumeAIModes.NotifyChanged();
        }
        return choice;
    }

    private async void EditResume_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { Resume: { } resume } kb) return;
        var dialog = new Windows.KnowledgeEntryEditorWindow(resume.Title, resume.Content, isNew: false,
            hint: LocalizationManager.Text("The AI summary is regenerated after you save the original."))
        { Owner = Owner };
        if (dialog.ShowDialog() != true) return;
        if (dialog.EntryContent == resume.Content && dialog.EntryTitle == resume.Title) return;
        await kb.UpdateResumeOriginalAsync(dialog.EntryTitle, dialog.EntryContent);
    }

    private async void RegenerateSummary_Click(object sender, RoutedEventArgs e)
    {
        if (Current is { } kb) await kb.RegenerateResumeSummaryAsync();
    }

    private void ResumeMore_Click(object sender, RoutedEventArgs e)
    {
        if (Current?.Resume is { } resume && sender is FrameworkElement anchor) ShowEntryMenu(anchor, resume, includeOpen: false);
    }

    private void DeleteResume_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { HasResume: true } kb) return;
        if (Windows.AppDialog.Show(Owner, LocalizationManager.Text("Delete resume?"), LocalizationManager.Text("DeleteResumeMessage"),
                Windows.DialogTone.Danger, LocalizationManager.Text("Delete"), LocalizationManager.Text("Cancel"), destructive: true))
            kb.DeleteResume();
    }

    // ───────────── skills / projects ─────────────

    private async void ExtractSkills_Click(object sender, RoutedEventArgs e)
    {
        if (Current is { } kb) await kb.ExtractSkillsFromResumeAsync();
    }

    private async void AddProject_Click(object sender, RoutedEventArgs e)
    {
        if (Current is { } kb) await kb.ImportProjectsAsync();
    }

    private async void ProjectUrl_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || Current is not { } kb) return;
        e.Handled = true;
        if (sender is TextBox box) box.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
        await kb.ImportProjectsAsync();
    }

    // ───────────── materials ─────────────

    private void AddMainContent_Click(object sender, RoutedEventArgs e)
    {
        if (Page is not { SelectedKnowledgeBase: not null } viewModel) return;
        var dialog = new Windows.KnowledgeEntryEditorWindow(LocalizationManager.Text("Note"), "", isNew: true) { Owner = Owner };
        if (dialog.ShowDialog() == true) viewModel.AddManualEntry(dialog.EntryTitle, dialog.EntryContent);
    }

    private void EditEntry_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: KnowledgeEntryViewModel entry }) return;
        var dialog = new Windows.KnowledgeEntryEditorWindow(entry.Title, entry.Content, isNew: false, pdfPath: entry.PdfPath) { Owner = Owner };
        if (dialog.ShowDialog() != true) return;
        entry.Title = dialog.EntryTitle;
        entry.Content = dialog.EntryContent;
    }

    private async void UploadFile_Click(object sender, RoutedEventArgs e)
    {
        if (Page is not { SelectedKnowledgeBase: { } kb } viewModel) return;
        var dialog = new OpenFileDialog
        {
            Title = LocalizationManager.Text("Upload File"),
            Filter = "Supported documents|*.pdf;*.txt;*.md;*.json;*.csv;*.html;*.htm;*.rtf;*.docx|Text files|*.txt;*.md;*.json;*.csv|All files|*.*",
            Multiselect = true
        };
        if (dialog.ShowDialog(Owner) != true) return;
        foreach (var file in dialog.FileNames)
        {
            try
            {
                var content = await DocumentTextImporter.ExtractTextAsync(file);
                if (string.IsNullOrWhiteSpace(content)) throw new InvalidDataException(LocalizationManager.Text("No readable text was found in this file."));
                // Offer to use it as this role's resume when it looks like one and there is none yet.
                if (!kb.HasResume && KnowledgeAssistant.LooksLikeResume(Path.GetFileName(file), content) &&
                    Windows.AppDialog.Show(Owner, LocalizationManager.Text("Use as resume?"), string.Format(LocalizationManager.Text("UseAsResumeMessage"), Path.GetFileName(file)),
                        Windows.DialogTone.Info, LocalizationManager.Text("Set as resume"), LocalizationManager.Text("Keep as material")))
                {
                    if (ChooseResumeProcessing() is { } useAI) await kb.ImportResumeAsync(file, useAI);
                    continue;
                }
                var source = $"file:{file}";
                if (string.Equals(Path.GetExtension(file), ".pdf", StringComparison.OrdinalIgnoreCase))
                {
                    // Like macOS storeImportedPDF: keep the original so the source editor can preview it.
                    var directory = Path.Combine(AppServices.Current.DataStore.DataDirectory, "ImportedPDFs");
                    Directory.CreateDirectory(directory);
                    var stored = Path.Combine(directory, $"{Guid.NewGuid()}.pdf");
                    File.Copy(file, stored, overwrite: true);
                    source = $"pdf:{stored}";
                }
                viewModel.AddFile(Path.GetFileNameWithoutExtension(file), content, source);
            }
            catch (Exception exception)
            {
                Windows.AppDialog.Show(Owner, LocalizationManager.Text("Import failed"), $"{Path.GetFileName(file)}\n{exception.Message}", Windows.DialogTone.Warning);
            }
        }
    }

    // ───────────── "⋯" menu: copy to another knowledge base, open, delete ─────────────

    private void EntryMore_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: KnowledgeEntryViewModel entry } anchor) ShowEntryMenu(anchor, entry, includeOpen: true);
    }

    private void ShowEntryMenu(FrameworkElement anchor, KnowledgeEntryViewModel entry, bool includeOpen)
    {
        if (Page is not { } page) return;
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom };

        var copyTo = new MenuItem { Header = LocalizationManager.Text("Copy to…") };
        var targets = page.CopyTargets(Current).ToList();
        if (targets.Count == 0)
        {
            copyTo.Items.Add(new MenuItem { Header = LocalizationManager.Text("No other knowledge bases"), IsEnabled = false });
        }
        foreach (var target in targets)
        {
            var item = new MenuItem { Header = target.Name };
            item.Click += (_, _) =>
            {
                if (entry.Kind == KnowledgeEntryKinds.Resume && target.HasResume &&
                    !Windows.AppDialog.Show(Owner, LocalizationManager.Text("Replace resume?"),
                        string.Format(LocalizationManager.Text("ReplaceTargetResumeMessage"), target.Name), Windows.DialogTone.Warning,
                        LocalizationManager.Text("Replace"), LocalizationManager.Text("Cancel")))
                    return;
                page.CopyEntryTo(entry, target);
            };
            copyTo.Items.Add(item);
        }
        menu.Items.Add(copyTo);

        if (includeOpen && entry.Url is { } url)
        {
            var open = new MenuItem { Header = LocalizationManager.Text(GitHubProjectImporter.IsGitHubUrl(url) ? "Open on GitHub" : "Open link") };
            open.Click += (_, _) => { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { } };
            menu.Items.Add(open);
        }

        if (includeOpen)
        {
            menu.Items.Add(new Separator());
            var delete = new MenuItem { Header = LocalizationManager.Text("Delete") };
            delete.SetResourceReference(MenuItem.ForegroundProperty, "DangerBrush");
            delete.Click += (_, _) => entry.DeleteCommand.Execute(null);
            menu.Items.Add(delete);
        }
        menu.IsOpen = true;
    }
}
