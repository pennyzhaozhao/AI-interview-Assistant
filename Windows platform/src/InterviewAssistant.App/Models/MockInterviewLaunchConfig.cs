namespace InterviewAssistant.Models;

public sealed record MockInterviewLaunchConfig(
    string Role,
    string JobDescription,
    IReadOnlyCollection<Guid> ActiveKnowledgeBaseIds,
    string Language,
    int QuestionCount = 6);
