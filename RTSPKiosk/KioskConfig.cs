using System;
using System.IO;
using Windows.Data.Json;
using Windows.Storage;

namespace RTSPKiosk
{
    /// <summary>Thrown with a message that is safe to show on screen.</summary>
    internal sealed class KioskConfigException : Exception
    {
        public KioskConfigException(string message) : base(message) { }
    }

    /// <summary>
    /// Camera settings, read from config.json. The per-user LocalState copy wins so one
    /// account can override the machine-wide file that Install-Kiosk.ps1 deploys.
    /// </summary>
    internal sealed class KioskConfig
    {
        private const string FileName = "config.json";
        private const string MachineFolder = @"C:\ProgramData\RTSPKiosk";

        public string Url { get; private set; }
        public string Username { get; private set; }
        public string Password { get; private set; }
        public string Transport { get; private set; }

        /// <summary>
        /// Just the host and port, for on-screen use. Credentials and the path are both left
        /// out because some cameras, such as UniFi Protect, use a secret token as the path.
        /// </summary>
        public string DisplayUrl
        {
            get
            {
                int authorityStart = Url.IndexOf("://", StringComparison.Ordinal) + 3;
                int authorityEnd = Url.IndexOfAny(new[] { '/', '?' }, authorityStart);
                if (authorityEnd < 0)
                {
                    authorityEnd = Url.Length;
                }

                int hostStart = FindUserInfoEnd(Url, authorityStart) + 1;
                hostStart = hostStart > 0 ? hostStart : authorityStart;
                return Url.Substring(0, authorityStart) + Url.Substring(hostStart, authorityEnd - hostStart);
            }
        }

        /// <summary>The address FFmpeg connects to, with credentials percent-encoded into it.</summary>
        public string BuildStreamUri()
        {
            if (Username.Length == 0)
            {
                return Url;
            }

            int authorityStart = Url.IndexOf("://", StringComparison.Ordinal) + 3;
            return Url.Substring(0, authorityStart)
                + Uri.EscapeDataString(Username) + ":" + Uri.EscapeDataString(Password) + "@"
                + Url.Substring(authorityStart);
        }

        public static KioskConfig Load()
        {
            string[] paths =
            {
                Path.Combine(ApplicationData.Current.LocalFolder.Path, FileName),
                Path.Combine(MachineFolder, FileName),
            };

            bool denied = false;
            foreach (string path in paths)
            {
                try
                {
                    return Parse(File.ReadAllText(path), path);
                }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
                catch (UnauthorizedAccessException) { denied = true; }
                catch (IOException ex)
                {
                    throw new KioskConfigException("Cannot read " + path + ": " + ex.Message);
                }
            }

            throw new KioskConfigException(denied
                ? "Access denied reading " + paths[1] + ". Re-run Install-Kiosk.ps1 to set its permissions."
                : "No configuration found. Expected " + paths[1]);
        }

        internal static KioskConfig Parse(string json, string source)
        {
            JsonObject root;
            if (!JsonObject.TryParse(json.TrimStart('\uFEFF'), out root))
            {
                throw new KioskConfigException(source + " is not valid JSON.");
            }

            var config = new KioskConfig
            {
                Url = root.GetNamedString("url", "").Trim(),
                Username = root.GetNamedString("username", ""),
                Password = root.GetNamedString("password", ""),
                Transport = root.GetNamedString("transport", "tcp").Trim().ToLowerInvariant(),
            };

            bool rtsp = config.Url.StartsWith("rtsp://", StringComparison.OrdinalIgnoreCase)
                || config.Url.StartsWith("rtsps://", StringComparison.OrdinalIgnoreCase);
            if (!rtsp)
            {
                throw new KioskConfigException(source + ": \"url\" must start with rtsp:// or rtsps://.");
            }

            if (config.Transport != "tcp" && config.Transport != "udp")
            {
                throw new KioskConfigException(source + ": \"transport\" must be \"tcp\" or \"udp\".");
            }

            int authorityStart = config.Url.IndexOf("://", StringComparison.Ordinal) + 3;
            if (config.Username.Length > 0 && FindUserInfoEnd(config.Url, authorityStart) >= 0)
            {
                throw new KioskConfigException(source + ": set credentials in \"url\" or in \"username\", not both.");
            }

            return config;
        }

        /// <summary>Index of the '@' ending the URL's user-info, or -1. An '@' in the path doesn't count.</summary>
        private static int FindUserInfoEnd(string url, int authorityStart)
        {
            int authorityEnd = url.IndexOf('/', authorityStart);
            if (authorityEnd < 0)
            {
                authorityEnd = url.Length;
            }

            return url.LastIndexOf('@', authorityEnd - 1, authorityEnd - authorityStart);
        }
    }
}
