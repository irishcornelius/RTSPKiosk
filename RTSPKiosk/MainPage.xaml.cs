using System;
using System.Threading;
using System.Threading.Tasks;
using FFmpegInteropX;
using Windows.ApplicationModel;
using Windows.Foundation;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.System.Display;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;

namespace RTSPKiosk
{
    /// <summary>
    /// Plays the camera for as long as the app is running. Nobody is there to press a button,
    /// so every failure (camera offline, network not up at boot, bad config) ends the same way:
    /// show why on screen, wait, and try again.
    /// </summary>
    public sealed partial class MainPage : Page
    {
        private static readonly TimeSpan SocketTimeout = TimeSpan.FromSeconds(10);
        private static readonly TimeSpan StallTimeout = TimeSpan.FromSeconds(15);
        private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(5);
        private static readonly TimeSpan WatchInterval = TimeSpan.FromSeconds(1);
        private static readonly TimeSpan SuspendGrace = TimeSpan.FromSeconds(3);

        private readonly MediaPlayer _player;
        private readonly DisplayRequest _displayRequest = new DisplayRequest();

        private CancellationTokenSource _stop;
        private Task _loop = Task.CompletedTask;
        private long _lastProgressTicks;

        public MainPage()
        {
            InitializeComponent();

            _player = new MediaPlayer
            {
                AudioCategory = MediaPlayerAudioCategory.Media,
                AutoPlay = true,
                IsMuted = false,
                RealTimePlayback = true,
                Volume = 1.0,
            };
            _player.CommandManager.IsEnabled = false;
            Video.SetMediaPlayer(_player);

            Loaded += OnLoaded;
            Application.Current.Suspending += OnSuspending;
            Application.Current.Resuming += OnResuming;
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            _displayRequest.RequestActive();
            StartLoop();
        }

        private async void OnSuspending(object sender, SuspendingEventArgs e)
        {
            SuspendingDeferral deferral = e.SuspendingOperation.GetDeferral();
            _stop?.Cancel();
            await Task.WhenAny(_loop, Task.Delay(SuspendGrace));
            deferral.Complete();
        }

        private void OnResuming(object sender, object e)
        {
            StartLoop();
        }

        private void StartLoop()
        {
            _stop = new CancellationTokenSource();
            _loop = RunAsync(_loop, _stop.Token);
        }

        /// <summary>Runs on the UI thread, so it can touch the player and controls directly.</summary>
        private async Task RunAsync(Task previousLoop, CancellationToken stop)
        {
            await previousLoop;

            while (!stop.IsCancellationRequested)
            {
                string reason;
                try
                {
                    reason = await PlayOnceAsync(stop);
                }
                catch (Exception ex)
                {
                    // Nothing may end this loop, or the kiosk sits on a black screen for good.
                    // Type and HRESULT only: exception text could echo the password.
                    reason = "Unexpected error: " + ex.GetType().Name + " (0x" + ex.HResult.ToString("X8") + ").";
                }

                if (stop.IsCancellationRequested)
                {
                    return;
                }

                ShowStatus(reason + "\nRetrying…");
                try
                {
                    await Task.Delay(RetryDelay, stop);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }

        /// <summary>Plays until the stream ends or fails, and returns why it stopped.</summary>
        private async Task<string> PlayOnceAsync(CancellationToken stop)
        {
            KioskConfig config;
            try
            {
                config = KioskConfig.Load();
            }
            catch (KioskConfigException ex)
            {
                return ex.Message;
            }

            var ended = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            TypedEventHandler<MediaPlayer, MediaPlayerFailedEventArgs> onFailed = (s, e) =>
                ended.TrySetResult("Playback failed: " + e.Error + " (0x" + e.ExtendedErrorCode.HResult.ToString("X8") + ").");
            TypedEventHandler<MediaPlayer, object> onEnded = (s, e) =>
                ended.TrySetResult("The camera closed the stream.");
            TypedEventHandler<MediaStreamSource, MediaStreamSourceSampleRequestedEventArgs> onSample = (s, e) =>
                MarkProgress();

            FFmpegMediaSource source = null;
            MediaStreamSource streamSource = null;
            _player.MediaFailed += onFailed;
            _player.MediaEnded += onEnded;
            try
            {
                ShowStatus("Connecting to " + config.DisplayUrl + "…");
                source = await FFmpegMediaSource
                    .CreateFromUriAsync(config.BuildStreamUri(), CreateSourceConfig(config))
                    .AsTask(stop);

                // The stream source doesn't exist until the playback item has been created.
                MediaPlaybackItem item = source.CreateMediaPlaybackItem();
                streamSource = source.GetMediaStreamSource();
                streamSource.SampleRequested += onSample;
                _player.Source = item;

                return await WatchAsync(source, ended.Task, stop);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex)
            {
                // Only the HRESULT: exception text could echo the URI, which carries the password.
                return "Could not open " + config.DisplayUrl + ": " + ex.GetType().Name + " (0x" + ex.HResult.ToString("X8") + ").";
            }
            finally
            {
                _player.MediaFailed -= onFailed;
                _player.MediaEnded -= onEnded;
                if (streamSource != null)
                {
                    streamSource.SampleRequested -= onSample;
                }

                _player.Source = null;
                source?.Dispose();
            }
        }

        private static MediaSourceConfig CreateSourceConfig(KioskConfig config)
        {
            var sourceConfig = new MediaSourceConfig();
            sourceConfig.General.ReadAheadBufferEnabled = false;
            sourceConfig.FFmpegOptions.Add("rtsp_transport", config.Transport);
            sourceConfig.FFmpegOptions.Add("timeout", ((long)SocketTimeout.TotalMilliseconds * 1000).ToString());
            sourceConfig.FFmpegOptions.Add("fflags", "nobuffer");
            return sourceConfig;
        }

        /// <summary>
        /// Waits for the player to report an end, and catches the case it doesn't report: a
        /// stream that silently stops delivering. Progress is either the clock moving or the
        /// pipeline consuming samples, because either alone may stand still in real-time mode.
        /// </summary>
        private async Task<string> WatchAsync(FFmpegMediaSource source, Task<string> ended, CancellationToken stop)
        {
            TimeSpan lastPosition = TimeSpan.Zero;
            bool started = false;
            MarkProgress();

            while (true)
            {
                Task finished = await Task.WhenAny(ended, Task.Delay(WatchInterval, stop));
                stop.ThrowIfCancellationRequested();
                if (finished == ended)
                {
                    return await ended;
                }

                MediaPlaybackSession session = _player.PlaybackSession;
                if (session.Position != lastPosition)
                {
                    lastPosition = session.Position;
                    MarkProgress();
                }

                if (!started && session.PlaybackState == MediaPlaybackState.Playing)
                {
                    started = true;
                    HideStatus();
                    ShowNotice(source.AudioStreams.Count == 0 ? "No audio track in this stream" : null);
                }

                long idleTicks = DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastProgressTicks);
                if (idleTicks > StallTimeout.Ticks)
                {
                    return "The stream stalled.";
                }
            }
        }

        private void MarkProgress()
        {
            Interlocked.Exchange(ref _lastProgressTicks, DateTime.UtcNow.Ticks);
        }

        private void ShowStatus(string text)
        {
            Status.Text = text;
            Status.Visibility = Visibility.Visible;
            ShowNotice(null);
        }

        private void HideStatus()
        {
            Status.Visibility = Visibility.Collapsed;
        }

        private void ShowNotice(string text)
        {
            Notice.Text = text ?? "";
            Notice.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
        }
    }
}
