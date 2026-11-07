using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace VeyMotion.Core;

/// <summary>
/// Connected accounts in the Windows Credential Manager (generic credentials, per user, DPAPI-protected), one per
/// account: target <c>VeyMotion:&lt;platform&gt;:&lt;userId&gt;</c> (= "VeyMotion:" + <see cref="SocialAccount.Key"/>), so
/// several YouTube channels (or TikTok / X / Facebook users) can stay connected and be switched between.
/// Port of <c>SocialKeychain</c>.
/// </summary>
/// <remarks>A credential blob holds at most 2,560 bytes; a longer account (e.g. Facebook with many Page tokens) is
/// split into continuation credentials <c>&lt;target&gt;~part1</c>, <c>~part2</c>, …</remarks>
public static partial class SocialCredentials
{
    public const string TargetPrefix = "VeyMotion:";
    const string PartSuffix = "~part";

    public static string Target(string key) => TargetPrefix + key;

    public static SocialAccount? Load(string key)
    {
        var target = Target(key);
        if (Native.Read(target) is not { } first) return null;
        var bytes = new List<byte>(first.Blob);
        for (var i = 1; Native.Read(target + PartSuffix + i) is { } part; i++) bytes.AddRange(part.Blob);
        return SocialAccount.FromJsonString(Encoding.UTF8.GetString(bytes.ToArray()));
    }

    /// <summary>Every connected account of <paramref name="platform"/>, oldest connection first.</summary>
    public static List<SocialAccount> Accounts(SocialPlatform platform)
    {
        var prefix = Target(platform.RawValue() + ":");
        return Native.EnumerateTargets(prefix + "*")
            .Where(t => t.StartsWith(prefix, StringComparison.Ordinal) && !PartRegex().IsMatch(t))
            .Select(t => Load(t[TargetPrefix.Length..]))
            .OfType<SocialAccount>()
            .OrderBy(a => a.ConnectedAt)
            .ToList();
    }

    public static void Save(SocialAccount account)
    {
        var target = Target(account.Key);
        var data = Encoding.UTF8.GetBytes(account.ToJsonString());
        var comment = $"VeyMotion — {account.Platform.Name()} — {account.DisplayName ?? account.UserId ?? ""}";
        var user = account.DisplayName ?? account.UserId ?? account.Platform.Name();
        try
        {
            var count = Math.Max(1, (data.Length + Native.MaxBlob - 1) / Native.MaxBlob);
            for (var i = 0; i < count; i++)
            {
                var chunk = data.AsSpan(i * Native.MaxBlob, Math.Min(Native.MaxBlob, data.Length - i * Native.MaxBlob)).ToArray();
                Native.Write(i == 0 ? target : target + PartSuffix + i, chunk, user, comment);
            }
            // Drop parts left over from a longer earlier save.
            for (var i = count; Native.Delete(target + PartSuffix + i); i++) { }
        }
        catch (Win32Exception e)
        {
            throw new PublishException($"Could not save the {account.Platform.Name()} login in the Credential Manager: {e.Message}");
        }
    }

    public static void Delete(string key)
    {
        var target = Target(key);
        Native.Delete(target);
        for (var i = 1; Native.Delete(target + PartSuffix + i); i++) { }
    }

    [GeneratedRegex(@"~part\d+$")]
    private static partial Regex PartRegex();

    /// <summary>advapi32 CredWriteW / CredReadW / CredDeleteW / CredEnumerateW (generic credentials).</summary>
    internal static class Native
    {
        const int CRED_TYPE_GENERIC = 1;
        const int CRED_PERSIST_LOCAL_MACHINE = 2;
        const int ERROR_NOT_FOUND = 1168;
        /// <summary>CRED_MAX_CREDENTIAL_BLOB_SIZE (5 * 512).</summary>
        internal const int MaxBlob = 5 * 512;

        [StructLayout(LayoutKind.Sequential)]
        struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public IntPtr TargetName;
            public IntPtr Comment;
            public long LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public IntPtr TargetAlias;
            public IntPtr UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", SetLastError = true)]
        static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredEnumerate(string? filter, int flags, out int count, out IntPtr credentials);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        static extern void CredFree(IntPtr buffer);

        internal sealed record Item(string Target, string? UserName, byte[] Blob);

        /// <summary>Creates or replaces a generic credential. Throws <see cref="Win32Exception"/>.</summary>
        internal static void Write(string target, byte[] blob, string? userName, string? comment)
        {
            if (blob.Length > MaxBlob) throw new ArgumentException("Credential blob too large", nameof(blob));
            var t = Marshal.StringToHGlobalUni(target);
            var c = comment == null ? IntPtr.Zero : Marshal.StringToHGlobalUni(comment);
            var u = userName == null ? IntPtr.Zero : Marshal.StringToHGlobalUni(userName);
            var b = Marshal.AllocHGlobal(Math.Max(blob.Length, 1));
            try
            {
                Marshal.Copy(blob, 0, b, blob.Length);
                var cred = new CREDENTIAL
                {
                    Type = CRED_TYPE_GENERIC,
                    TargetName = t,
                    Comment = c,
                    CredentialBlobSize = blob.Length,
                    CredentialBlob = b,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    UserName = u,
                };
                if (!CredWrite(ref cred, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally
            {
                // Tokens: wipe the unmanaged copy before freeing it.
                for (var i = 0; i < blob.Length; i++) Marshal.WriteByte(b, i, 0);
                Marshal.FreeHGlobal(b);
                Marshal.FreeHGlobal(t);
                if (c != IntPtr.Zero) Marshal.FreeHGlobal(c);
                if (u != IntPtr.Zero) Marshal.FreeHGlobal(u);
            }
        }

        /// <summary>The credential, or null when there is none (other failures throw).</summary>
        internal static Item? Read(string target)
        {
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out var p))
            {
                var err = Marshal.GetLastWin32Error();
                if (err == ERROR_NOT_FOUND) return null;
                throw new Win32Exception(err);
            }
            try { return ItemAt(p); }
            finally { CredFree(p); }
        }

        /// <summary>True when something was deleted.</summary>
        internal static bool Delete(string target) => CredDelete(target, CRED_TYPE_GENERIC, 0);

        /// <summary>Target names matching <paramref name="filter"/> (a trailing "*" is a wildcard).</summary>
        internal static List<string> EnumerateTargets(string filter)
        {
            var output = new List<string>();
            if (!CredEnumerate(filter, 0, out var count, out var list))
            {
                var err = Marshal.GetLastWin32Error();
                if (err == ERROR_NOT_FOUND) return output;
                throw new Win32Exception(err);
            }
            try
            {
                for (var i = 0; i < count; i++)
                {
                    var p = Marshal.ReadIntPtr(list, i * IntPtr.Size);
                    var cred = Marshal.PtrToStructure<CREDENTIAL>(p);
                    if (cred.Type == CRED_TYPE_GENERIC && Marshal.PtrToStringUni(cred.TargetName) is { } name) output.Add(name);
                }
            }
            finally { CredFree(list); }
            return output;
        }

        static Item ItemAt(IntPtr p)
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(p);
            var blob = new byte[cred.CredentialBlobSize];
            if (cred.CredentialBlobSize > 0) Marshal.Copy(cred.CredentialBlob, blob, 0, blob.Length);
            return new Item(Marshal.PtrToStringUni(cred.TargetName) ?? "", Marshal.PtrToStringUni(cred.UserName), blob);
        }
    }
}

/// <summary>
/// Small publishing preferences in <c>%LOCALAPPDATA%\VeyMotion\publish.json</c> (the macOS app keeps them in
/// UserDefaults): the account each platform posts with (<c>publish.account.&lt;platform&gt;</c>) plus any other string
/// setting the Publish sheet wants to remember (Swift's <c>publish.platform</c>, <c>publish.youtubePrivacy</c>,
/// <c>publish.tiktokMode</c>, <c>publish.facebookPage</c>, <c>publish.preset</c>, <c>publish.fit</c>, <c>publish.quality</c>).
/// </summary>
public static class PublishSettings
{
    static readonly Lock Gate = new();
    static Dictionary<string, string>? _values;

    /// <summary>Overridable for tests.</summary>
    public static string FilePath { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VeyMotion", "publish.json");

    public static string? Get(string key)
    {
        lock (Gate) return Values().GetValueOrDefault(key);
    }

    /// <summary>Sets (or with null removes) a value and writes the file.</summary>
    public static void Set(string key, string? value)
    {
        lock (Gate)
        {
            var v = Values();
            if (value == null) { if (!v.Remove(key)) return; }
            else if (v.TryGetValue(key, out var old) && old == value) return;
            else v[key] = value;
            Write(v);
        }
    }

    static string AccountKey(SocialPlatform p) => $"publish.account.{p.RawValue()}";

    /// <summary>The <see cref="SocialAccount.Key"/> <paramref name="p"/> posts with, remembered across launches.</summary>
    public static string? ActiveAccount(SocialPlatform p) => Get(AccountKey(p));

    public static void SetActiveAccount(SocialPlatform p, string? accountKey) => Set(AccountKey(p), accountKey);

    /// <summary>The account <paramref name="p"/> posts with: the one chosen last, else the first connected.</summary>
    public static SocialAccount? ResolveActive(SocialPlatform p, IReadOnlyList<SocialAccount> accounts)
    {
        var key = ActiveAccount(p);
        return accounts.FirstOrDefault(a => a.Key == key) ?? accounts.FirstOrDefault();
    }

    static Dictionary<string, string> Values()
    {
        if (_values != null) return _values;
        var v = new Dictionary<string, string>();
        try
        {
            if (JsonNode.Parse(File.ReadAllText(FilePath, Encoding.UTF8)) is JsonObject o)
                foreach (var (k, n) in o)
                    if (n is JsonValue jv && jv.GetValueKind() == JsonValueKind.String) v[k] = jv.GetValue<string>();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return _values = v;
    }

    static void Write(Dictionary<string, string> v)
    {
        var o = new JsonObject();
        foreach (var (k, s) in v.OrderBy(x => x.Key, StringComparer.Ordinal)) o[k] = s;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var part = FilePath + ".part";
            File.WriteAllText(part, o.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            File.Move(part, FilePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
