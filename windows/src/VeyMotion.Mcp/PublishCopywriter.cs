using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VeyMotion.Core;

namespace VeyMotion.Mcp;

/// <summary>One tool-less <c>claude -p</c> turn whose answer must match a JSON Schema. Port of
/// <c>ClaudeCodeAgent.structured</c> (kept in its own class so <c>ClaudeCodeAgent.cs</c> is untouched).</summary>
public static class ClaudeStructured
{
    /// <summary>The command-line arguments (the prompt goes in on stdin).</summary>
    public static List<string> Arguments(JsonObject schema, string? model)
    {
        var args = new List<string>
        {
            "-p", "--output-format", "json", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--no-session-persistence", "--json-schema", schema.ToJsonString(),
        };
        if (!string.IsNullOrEmpty(model)) args.AddRange(["--model", model]);
        return args;
    }

    /// <summary>Runs <c>claude -p --output-format json --tools "" --json-schema &lt;schema&gt;</c> with
    /// <paramref name="prompt"/> on stdin and returns the structured answer. Throws <see cref="InvalidOperationException"/>
    /// with a readable message on failure and <see cref="OperationCanceledException"/> when cancelled.</summary>
    public static async Task<JsonObject> RunAsync(string prompt, JsonObject schema, string claudePath, string? model = null,
        string? workingDirectory = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var dir = workingDirectory ?? AppPaths.AgentWorkingDirectory;
        Directory.CreateDirectory(dir);
        var psi = new ProcessStartInfo(claudePath)
        {
            WorkingDirectory = dir,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in Arguments(schema, model)) psi.ArgumentList.Add(a);

        Process p;
        try { p = Process.Start(psi) ?? throw new InvalidOperationException("Could not start Claude Code"); }
        catch (System.ComponentModel.Win32Exception e) { throw new InvalidOperationException($"Could not start Claude Code: {e.Message}"); }
        using var _ = p;
        var stdout = p.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var stderr = p.StandardError.ReadToEndAsync(CancellationToken.None);
        try
        {
            await p.StandardInput.WriteAsync(prompt);
            p.StandardInput.Close();
        }
        catch (IOException) { /* exited early; reported below */ }

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? TimeSpan.FromSeconds(120));
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException)
        {
            try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            if (ct.IsCancellationRequested) throw new OperationCanceledException("Cancelled", ct);
            throw new InvalidOperationException("Claude took too long to answer.");
        }
        var output = await stdout;
        var errors = await stderr;

        JsonObject? obj = null;
        try { obj = JsonNode.Parse(output) as JsonObject; }
        catch (JsonException) { }
        if (obj == null)
        {
            var detail = (errors.Length == 0 ? output[..Math.Min(output.Length, 400)] : errors).Trim();
            throw new InvalidOperationException($"Claude did not answer (exit {p.ExitCode}). {detail[..Math.Min(detail.Length, 400)]}");
        }
        if (obj["is_error"] is JsonValue ie && ie.GetValueKind() == JsonValueKind.True)
            throw new InvalidOperationException($"Claude: {Str(obj, "result") ?? Str(obj, "subtype") ?? "error"}");
        if (obj["structured_output"] is JsonObject s) return (JsonObject)s.DeepClone();
        // Older CLIs: the JSON answer is in `result`.
        if (Str(obj, "result") is { } text)
        {
            try { if (JsonNode.Parse(text) is JsonObject r) return r; }
            catch (JsonException) { }
        }
        throw new InvalidOperationException("Claude's answer was not in the expected format.");
    }

    internal static string? Str(JsonNode? o, string key) =>
        o?[key] is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;
}

/// <summary>Title, description, tags and caption for a post.</summary>
public sealed record PublishCopy(string Title = "", string Description = "", IReadOnlyList<string>? Tags = null, string Caption = "")
{
    public IReadOnlyList<string> Tags { get; init; } = Tags ?? [];
}

/// <summary>"Write with Claude": drafts publishing copy with the user's Claude Code (<c>claude -p</c>, no tools), from
/// what is in the scene: on-screen text, voice-over transcripts and media file names. Port of <c>PublishCopy.swift</c>.</summary>
public static class PublishCopywriter
{
    /// <summary>Drafts the copy. <paramref name="claudePath"/> defaults to <see cref="ClaudeCodeAgent.LocateClaude"/>;
    /// <paramref name="model"/> is the chat's model setting (null/empty = Claude Code's default).
    /// Errors are <see cref="PublishException"/> with a message for the user.</summary>
    public static async Task<PublishCopy> WriteAsync(MotionScene scene, string name, SocialPlatform platform, PublishCopy draft,
        string notes, string? claudePath = null, string? model = null, CancellationToken ct = default)
    {
        var claude = claudePath ?? ClaudeCodeAgent.LocateClaude()
            ?? throw new PublishException("Claude Code is not installed (the `claude` command was not found). Install it from claude.com/claude-code.");
        JsonObject output;
        try
        {
            output = await ClaudeStructured.RunAsync(Prompt(scene, name, platform, draft, notes), Schema(), claude, model, ct: ct);
        }
        catch (InvalidOperationException e) { throw new PublishException(e.Message); }
        var title = ClaudeStructured.Str(output, "title") ?? "";
        var limit = platform == SocialPlatform.Youtube ? 100 : 255;
        var tags = (output["tags"] as JsonArray ?? [])
            .OfType<JsonValue>().Where(v => v.GetValueKind() == JsonValueKind.String)
            .Select(v => v.GetValue<string>().Trim('#', ' '))
            .Where(t => t.Length > 0).ToList();
        return new PublishCopy(
            title.Length > limit ? title[..limit] : title,
            ClaudeStructured.Str(output, "description") ?? "",
            tags,
            ClaudeStructured.Str(output, "caption") ?? "");
    }

    /// <summary>The JSON Schema the answer must match.</summary>
    public static JsonObject Schema() => new()
    {
        ["type"] = "object",
        ["properties"] = new JsonObject
        {
            ["title"] = new JsonObject { ["type"] = "string", ["description"] = "Video title (YouTube, Facebook). Empty for TikTok and X." },
            ["description"] = new JsonObject { ["type"] = "string", ["description"] = "Video description (YouTube, Facebook). Empty for TikTok and X." },
            ["tags"] = new JsonObject
            {
                ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" },
                ["description"] = "YouTube keyword tags, without #. Empty for other platforms.",
            },
            ["caption"] = new JsonObject { ["type"] = "string", ["description"] = "Post text with hashtags (TikTok, X). Empty for YouTube and Facebook." },
        },
        ["required"] = new JsonArray("title", "description", "tags", "caption"),
    };

    public static string Prompt(MotionScene scene, string name, SocialPlatform platform, PublishCopy draft, string notes)
    {
        var vertical = scene.Height > scene.Width;
        var lines = new List<string>
        {
            $"You write the text that goes with a video when it is published on {platform.Name()}. Answer with the JSON fields only.",
            "",
            "VIDEO",
            $"- Project name: {name}",
            $"- {scene.Width}×{scene.Height} ({(vertical ? "vertical" : scene.Width == scene.Height ? "square" : "horizontal")}), "
                + $"{PlatformPreset.FormatDuration(scene.Duration)}, {scene.Fps} fps",
        };

        var layers = scene.Layers.OrderBy(l => l.Start).ToList();
        var seen = new HashSet<string>();
        var texts = new List<string>();
        var budget = 5000;
        foreach (var l in layers.Where(l => l.Type == LayerType.Text))
        {
            var t = (l.Text ?? "").Trim();
            if (t.Length == 0 || !seen.Add(t) || budget <= 0) continue;
            var entry = $"  [{l.Start.ToString("0.0", CultureInfo.InvariantCulture)}s] {t.Replace("\n", " / ")}";
            texts.Add(entry.Length > budget ? entry[..budget] : entry);
            budget -= entry.Length;
        }
        if (texts.Count > 0)
        {
            lines.Add("- On-screen text, in order of appearance:");
            lines.AddRange(texts);
        }
        var voice = layers.Select(l => l.Transcript?.Trim()).Where(s => !string.IsNullOrEmpty(s)).Cast<string>().ToList();
        if (voice.Count > 0)
        {
            lines.Add("- Voice-over:");
            lines.AddRange(voice.Select(v => "  " + (v.Length > 4000 ? v[..4000] : v)));
        }
        var media = layers
            .Where(l => l.Path != null && l.Type is LayerType.Image or LayerType.Video or LayerType.Audio)
            .Select(l =>
            {
                var role = l.Type == LayerType.Audio ? $"{l.Role.ToString().ToLowerInvariant()} audio" : l.Type.ToString().ToLowerInvariant();
                return $"  {role}: {Path.GetFileName(l.Path!.TrimEnd('/', '\\'))}";
            })
            .Distinct().Order(StringComparer.Ordinal).Take(30).ToList();
        if (media.Count > 0)
        {
            lines.Add("- Media files (names may hint at the song or subject):");
            lines.AddRange(media);
        }

        lines.Add("");
        lines.Add($"RULES FOR {platform.Name().ToUpperInvariant()}");
        switch (platform)
        {
            case SocialPlatform.Youtube:
                lines.Add("- title: at most 100 characters (aim for 40–70), specific and inviting, no all caps, no clickbait.");
                lines.Add("- description: 2–4 short paragraphs saying what the video is, then 3–5 hashtags on the last line.");
                lines.Add("- tags: 5–15 search keywords, under 450 characters in total.");
                if (vertical && scene.Duration <= 180) lines.Add("- This will be a YouTube Short: include #Shorts in the description's hashtags.");
                lines.Add("- caption: empty.");
                break;
            case SocialPlatform.Tiktok:
                lines.Add("- caption: a short hook (1–2 sentences) then 3–6 relevant hashtags, under 300 characters.");
                lines.Add("- title, description: empty. tags: empty.");
                break;
            case SocialPlatform.Facebook:
                lines.Add("- title: at most 100 characters.");
                lines.Add("- description: 1–3 short paragraphs, then 2–4 hashtags.");
                lines.Add("- tags, caption: empty.");
                break;
            case SocialPlatform.X:
                lines.Add("- caption: at most 240 characters including 1–2 hashtags; punchy, no thread.");
                lines.Add("- title, description: empty. tags: empty.");
                break;
        }

        lines.Add("");
        lines.Add("GENERAL");
        lines.Add("- Write in the language of the video's text and voice-over (e.g. Vietnamese with full diacritics). "
            + "If the video has no words, use the language of the project name or the draft.");
        lines.Add("- Only state what the content supports; do not invent names, dates, prices or claims.");
        lines.Add("- No emoji spam: at most 2 emoji.");
        lines.Add("- Never mention technical details (resolution, orientation, fps, file names, the editor used); "
            + "the details above are only context. Media file names may tell you the song or subject.");

        var draftLines = new[]
            {
                ("title", draft.Title), ("description", draft.Description),
                ("tags", string.Join(", ", draft.Tags)), ("caption", draft.Caption),
            }
            .Where(d => d.Item2.Trim().Length > 0 && d.Item2 != name).ToList();
        if (draftLines.Count > 0)
        {
            lines.Add("");
            lines.Add("THE USER'S DRAFT (keep its intent and any facts it states; improve the wording):");
            lines.AddRange(draftLines.Select(d => $"- {d.Item1}: {d.Item2}"));
        }
        var n = notes.Trim();
        if (n.Length > 0)
        {
            lines.Add("");
            lines.Add($"THE USER'S INSTRUCTIONS (follow them): {n}");
        }
        return string.Join("\n", lines);
    }
}
