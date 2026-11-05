using System;
using System.IO;
using Windows.ApplicationModel.Activation;
using Windows.Storage;
using Windows.UI.ViewManagement;
using Windows.UI.Xaml;

namespace RTSPKiosk
{
    public sealed partial class App : Application
    {
        public App()
        {
            InitializeComponent();
            UnhandledException += OnUnhandledException;
        }

        /// <summary>
        /// Records the crash in LocalState\crash.log, then lets the app die so Assigned Access
        /// restarts it. The exception text is left out because it could echo the password.
        /// </summary>
        private void OnUnhandledException(object sender, Windows.UI.Xaml.UnhandledExceptionEventArgs e)
        {
            try
            {
                Exception ex = e.Exception;
                string entry = DateTimeOffset.Now.ToString("o") + " " + ex.GetType().FullName
                    + " 0x" + ex.HResult.ToString("X8") + Environment.NewLine
                    + ex.StackTrace + Environment.NewLine;
                File.AppendAllText(Path.Combine(ApplicationData.Current.LocalFolder.Path, "crash.log"), entry);
            }
            catch (Exception)
            {
                // The app is already going down; failing to log must not hide the original crash.
            }
        }

        protected override void OnLaunched(LaunchActivatedEventArgs e)
        {
            // Applies from the next launch; TryEnterFullScreenMode below covers this one.
            ApplicationView.PreferredLaunchWindowingMode = ApplicationViewWindowingMode.FullScreen;

            if (Window.Current.Content == null)
            {
                Window.Current.Content = new MainPage();
            }

            Window.Current.Activate();

            ApplicationView view = ApplicationView.GetForCurrentView();
            view.FullScreenSystemOverlayMode = FullScreenSystemOverlayMode.Minimal;
            view.TryEnterFullScreenMode();
            Window.Current.CoreWindow.PointerCursor = null;
        }
    }
}
