namespace VeyMotion.Mcp;

/// <summary>Where VeyMotion keeps its files on Windows (macOS: ~/Library/Application Support/VeyMotion).</summary>
public static class AppPaths
{
    /// <summary>%LOCALAPPDATA%\VeyMotion</summary>
    public static string SupportDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VeyMotion");

    /// <summary>Working directory of the embedded agent.</summary>
    public static string AgentWorkingDirectory => Path.Combine(SupportDirectory, "agent");

    /// <summary>Where <c>render_frame</c> results are saved for the agent to Read.</summary>
    public static string FramesDirectory =>
        Environment.GetEnvironmentVariable("VEYMOTION_FRAMES_DIR") is { Length: > 0 } p ? p : Path.Combine(AgentWorkingDirectory, "frames");
}
