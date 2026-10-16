using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

// Animate a small retained visual tree inside a fixed native window. Resizing
// a transparent HWND on every frame reallocates its layered backing surface.
public sealed class CachedFoldMotion : IDisposable
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int width, int height, uint flags);

    private readonly Window window;
    private readonly Grid root;
    private readonly Border surface;
    private readonly FrameworkElement expandedLayout;
    private readonly Grid compactLayout;
    private Canvas overlay;
    private Border shell;
    private readonly Stopwatch clock = new Stopwatch();
    private bool expanding;
    private double targetLeft, targetTop, targetWidth, targetHeight;
    private double savedWidth, savedHeight;
    private double previousFrame;
    private TimeSpan previousRenderingTime;
    private BitmapSource cachedFull;
    private double cachedFullWidth, cachedFullHeight;
    private bool disposed;

    public event EventHandler Completed;
    public bool IsActive { get; private set; }
    public int LastFrameCount { get; private set; }
    public double LastDurationMilliseconds { get; private set; }
    public double LastMaxFrameMilliseconds { get; private set; }
    public double LastPreparationMilliseconds { get; private set; }
    public double LastRestoreMilliseconds { get; private set; }
    public string LastError { get; private set; }

    public CachedFoldMotion(Window window, Border surface, FrameworkElement expanded, Grid compact)
    {
        this.window = window;
        this.root = (Grid)window.Content;
        this.surface = surface;
        this.expandedLayout = expanded;
        this.compactLayout = compact;
    }

    private void SetBounds(double left, double top, double width, double height)
    {
        HwndSource source = (HwndSource)PresentationSource.FromVisual(window);
        Matrix matrix = source.CompositionTarget.TransformToDevice;
        if (!SetWindowPos(source.Handle, IntPtr.Zero,
            (int)Math.Round(left * matrix.M11), (int)Math.Round(top * matrix.M22),
            (int)Math.Round(width * matrix.M11), (int)Math.Round(height * matrix.M22),
            0x0004 | 0x0010))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    private BitmapSource Capture(double width, double height, bool full)
    {
        Visibility expectedFull = full ? Visibility.Visible : Visibility.Collapsed;
        Visibility expectedSmall = full ? Visibility.Collapsed : Visibility.Visible;
        bool alreadyArranged = expandedLayout.Visibility == expectedFull &&
            compactLayout.Visibility == expectedSmall && surface.Visibility == Visibility.Visible &&
            Math.Abs(surface.RenderSize.Width - width) < 0.1 &&
            Math.Abs(surface.RenderSize.Height - height) < 0.1;
        if (!alreadyArranged)
        {
            expandedLayout.Visibility = expectedFull;
            compactLayout.Visibility = expectedSmall;
            surface.Visibility = Visibility.Visible;
            surface.Width = width;
            surface.Height = height;
            surface.Measure(new Size(width, height));
            surface.Arrange(new Rect(0, 0, width, height));
            surface.UpdateLayout();
        }
        HwndSource source = (HwndSource)PresentationSource.FromVisual(window);
        Matrix matrix = source.CompositionTarget.TransformToDevice;
        RenderTargetBitmap bitmap = new RenderTargetBitmap(
            Math.Max(1, (int)Math.Ceiling(width * matrix.M11)),
            Math.Max(1, (int)Math.Ceiling(height * matrix.M22)),
            96 * matrix.M11, 96 * matrix.M22, PixelFormats.Pbgra32);
        bitmap.Render(surface);
        bitmap.Freeze();
        return bitmap;
    }

    private static Image MakeImage(BitmapSource source, double width, double height)
    {
        Image image = new Image();
        image.Source = source;
        image.Width = width;
        image.Height = height;
        image.Stretch = Stretch.Fill;
        image.HorizontalAlignment = HorizontalAlignment.Right;
        image.VerticalAlignment = VerticalAlignment.Top;
        image.IsHitTestVisible = false;
        return image;
    }

    private static DoubleAnimation Motion(double from, double to, int milliseconds)
    {
        DoubleAnimation animation = new DoubleAnimation(from, to,
            TimeSpan.FromMilliseconds(milliseconds));
        animation.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut };
        Timeline.SetDesiredFrameRate(animation, 60);
        return animation;
    }

    public void Start(bool expand, double left, double top, double width, double height)
    {
        if (disposed) throw new ObjectDisposedException("CachedFoldMotion");
        if (IsActive) return;
        if (Double.IsNaN(width) || Double.IsNaN(height) || Double.IsInfinity(width) ||
            Double.IsInfinity(height) || width <= 0 || height <= 0)
            throw new ArgumentOutOfRangeException("width", "Animation bounds must be finite and positive.");
        IsActive = true;
        LastError = null;
        expanding = expand;
        targetLeft = left; targetTop = top; targetWidth = width; targetHeight = height;
        savedWidth = surface.Width; savedHeight = surface.Height;
        double startLeft = window.Left, startTop = window.Top;
        double startWidth = window.ActualWidth, startHeight = window.ActualHeight;
        double fullWidth = expand ? width : startWidth;
        double fullHeight = expand ? height : startHeight;
        double smallWidth = expand ? startWidth : width;
        double smallHeight = expand ? startHeight : height;
        Stopwatch preparation = Stopwatch.StartNew();
        try
        {
            // While expanding, reuse the full view captured when it was folded.
            // The real controls show their latest values when the motion ends.
            BitmapSource full = expand && cachedFull != null &&
                Math.Abs(cachedFullWidth - fullWidth) < 0.1 &&
                Math.Abs(cachedFullHeight - fullHeight) < 0.1 ?
                cachedFull : Capture(fullWidth, fullHeight, true);
            cachedFull = full; cachedFullWidth = fullWidth; cachedFullHeight = fullHeight;
            BitmapSource small = Capture(smallWidth, smallHeight, false);
            // Keep the real layout out of every animation-frame measure pass.
            surface.Visibility = Visibility.Collapsed;
            double envelopeLeft = Math.Min(startLeft, left);
            double envelopeTop = Math.Min(startTop, top);
            double envelopeRight = Math.Max(startLeft + startWidth, left + width);
            double envelopeBottom = Math.Max(startTop + startHeight, top + height);
            SetBounds(envelopeLeft, envelopeTop,
                envelopeRight - envelopeLeft, envelopeBottom - envelopeTop);

            overlay = new Canvas { IsHitTestVisible = false, ClipToBounds = true };
            Panel.SetZIndex(overlay, 200);
            shell = new Border { CornerRadius = new CornerRadius(26),
                Background = surface.Background.CloneCurrentValue(),
                Width = startWidth, Height = startHeight };
            Grid images = new Grid();
            RectangleGeometry clip = new RectangleGeometry(
                new Rect(0, 0, startWidth, startHeight), 26, 26);
            images.Clip = clip;
            Image fullImage = MakeImage(full, fullWidth, fullHeight);
            Image smallImage = MakeImage(small, smallWidth, smallHeight);
            images.Children.Add(fullImage);
            images.Children.Add(smallImage);
            fullImage.Opacity = expand ? 0 : 1;
            smallImage.Opacity = expand ? 1 : 0;
            shell.Child = images;
            Canvas.SetLeft(shell, startLeft - envelopeLeft);
            Canvas.SetTop(shell, startTop - envelopeTop);
            overlay.Children.Add(shell);
            root.Children.Add(overlay);
            root.UpdateLayout();

            const int duration = 220;
            DoubleAnimation finish = Motion(startWidth, width, duration);
            finish.Completed += OnAnimationCompleted;
            shell.BeginAnimation(FrameworkElement.WidthProperty, finish);
            shell.BeginAnimation(FrameworkElement.HeightProperty,
                Motion(startHeight, height, duration));
            shell.BeginAnimation(Canvas.LeftProperty,
                Motion(startLeft - envelopeLeft, left - envelopeLeft, duration));
            shell.BeginAnimation(Canvas.TopProperty,
                Motion(startTop - envelopeTop, top - envelopeTop, duration));
            RectAnimation clipAnimation = new RectAnimation(
                new Rect(0, 0, startWidth, startHeight), new Rect(0, 0, width, height),
                TimeSpan.FromMilliseconds(duration));
            clipAnimation.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut };
            clip.BeginAnimation(RectangleGeometry.RectProperty, clipAnimation);
            fullImage.BeginAnimation(UIElement.OpacityProperty,
                Motion(expand ? 0 : 1, expand ? 1 : 0, duration));
            smallImage.BeginAnimation(UIElement.OpacityProperty,
                Motion(expand ? 1 : 0, expand ? 0 : 1, duration));
            LastFrameCount = 0; LastMaxFrameMilliseconds = 0;
            previousFrame = 0;
            previousRenderingTime = TimeSpan.MinValue;
            LastPreparationMilliseconds = preparation.Elapsed.TotalMilliseconds;
            clock.Restart();
            CompositionTarget.Rendering += OnRendering;
        }
        catch
        {
            try { Restore(); }
            catch (Exception cleanupError) { LastError = cleanupError.Message; }
            throw;
        }
    }

    private void OnRendering(object sender, EventArgs args)
    {
        RenderingEventArgs rendering = args as RenderingEventArgs;
        if (rendering != null)
        {
            if (rendering.RenderingTime == previousRenderingTime) return;
            previousRenderingTime = rendering.RenderingTime;
        }
        double now = clock.Elapsed.TotalMilliseconds;
        if (LastFrameCount > 0)
            LastMaxFrameMilliseconds = Math.Max(LastMaxFrameMilliseconds, now - previousFrame);
        previousFrame = now;
        LastFrameCount++;
    }

    private void OnAnimationCompleted(object sender, EventArgs args)
    {
        if (!IsActive) return;
        LastDurationMilliseconds = clock.Elapsed.TotalMilliseconds;
        try { Restore(); }
        catch (Exception restoreError) { LastError = restoreError.Message; }
        finally
        {
            EventHandler completed = Completed;
            if (completed != null) completed(this, EventArgs.Empty);
        }
    }

    private void Restore()
    {
        Stopwatch restore = Stopwatch.StartNew();
        CompositionTarget.Rendering -= OnRendering;
        try
        {
            if (overlay != null) root.Children.Remove(overlay);
            surface.Width = savedWidth; surface.Height = savedHeight;
            expandedLayout.Visibility = expanding ? Visibility.Visible : Visibility.Collapsed;
            compactLayout.Visibility = expanding ? Visibility.Collapsed : Visibility.Visible;
            SetBounds(targetLeft, targetTop, targetWidth, targetHeight);
        }
        finally
        {
            overlay = null; shell = null;
            surface.Visibility = Visibility.Visible;
            IsActive = false;
            try
            {
                surface.InvalidateMeasure();
                root.UpdateLayout();
            }
            finally { LastRestoreMilliseconds = restore.Elapsed.TotalMilliseconds; }
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        CompositionTarget.Rendering -= OnRendering;
        if (overlay != null) root.Children.Remove(overlay);
        overlay = null;
        cachedFull = null;
        disposed = true;
    }
}

// During an interactive resize, scale one bitmap rather than re-measuring
// every card, label and plotted point for every mouse sample.
public sealed class CachedResizePreview : IDisposable
{
    private readonly Window window;
    private readonly Border surface;
    private readonly Panel root;
    private Image preview;
    private Border previewHost;
    private RectangleGeometry previewClip;
    public bool IsActive { get; private set; }

    public CachedResizePreview(Window window, Border surface)
    {
        this.window = window;
        this.surface = surface;
        root = (Panel)window.Content;
    }

    public void Begin()
    {
        if (IsActive) return;
        // Capture the content without the old window's rim/background. The
        // new host draws its glass at the current size; content scales uniformly.
        Visual capture = surface.Child as Visual ?? surface;
        UIElement element = capture as UIElement;
        double width = element == null ? surface.ActualWidth : element.RenderSize.Width;
        double height = element == null ? surface.ActualHeight : element.RenderSize.Height;
        if (width <= 0 || height <= 0) return;
        HwndSource source = (HwndSource)PresentationSource.FromVisual(window);
        Matrix matrix = source.CompositionTarget.TransformToDevice;
        RenderTargetBitmap bitmap = new RenderTargetBitmap(
            Math.Max(1, (int)Math.Ceiling(width * matrix.M11)),
            Math.Max(1, (int)Math.Ceiling(height * matrix.M22)),
            96 * matrix.M11, 96 * matrix.M22, PixelFormats.Pbgra32);
        bitmap.Render(capture);
        bitmap.Freeze();
        preview = new Image { Source = bitmap, Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch, IsHitTestVisible = false };
        previewHost = new Border { Child = preview,
            Background = surface.Background == null ? null : surface.Background.CloneCurrentValue(),
            BorderBrush = surface.BorderBrush == null ? null : surface.BorderBrush.CloneCurrentValue(),
            BorderThickness = surface.BorderThickness, CornerRadius = surface.CornerRadius,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch, IsHitTestVisible = false };
        previewClip = new RectangleGeometry();
        previewHost.Clip = previewClip;
        previewHost.SizeChanged += OnPreviewSizeChanged;
        Panel.SetZIndex(previewHost, 90);
        root.Children.Add(previewHost);
        // Keep the authored tree out of layout while the snapshot fills the
        // current window independently. Restore it once at the final size.
        surface.Visibility = Visibility.Collapsed;
        IsActive = true;
    }

    private void OnPreviewSizeChanged(object sender, SizeChangedEventArgs args)
    {
        // Only the outline follows the new aspect ratio. Glyphs, circles and
        // data labels share one scale factor throughout the drag.
        double radius = surface.CornerRadius.TopLeft;
        previewClip.Rect = new Rect(0, 0, args.NewSize.Width, args.NewSize.Height);
        previewClip.RadiusX = radius;
        previewClip.RadiusY = radius;
    }

    public void End()
    {
        try
        {
            if (previewHost != null) {
                previewHost.SizeChanged -= OnPreviewSizeChanged;
                root.Children.Remove(previewHost);
                previewHost.Child = null;
            }
            if (preview != null) preview.Source = null;
        }
        finally
        {
            preview = null;
            previewHost = null;
            previewClip = null;
            surface.Visibility = Visibility.Visible;
            IsActive = false;
        }
    }

    public void Dispose() { End(); }
}

// Poll the latest physical cursor position once per frame. Mouse samples do
// not queue PowerShell callbacks or four separate HWND geometry changes.
public sealed class WidgetResizeDriver : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetPhysicalCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern IntPtr GetCapture();
    [DllImport("user32.dll")] private static extern IntPtr SetCapture(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int width, int height, uint flags);
    private readonly DispatcherTimer timer;
    private IntPtr handle;
    private Point cursorStart, lastCursor;
    private int[] start;
    private string edge;
    private int minWidth, minHeight;
    public bool IsActive { get; private set; }
    public int UpdateCount { get; private set; }
    public event EventHandler Completed;

    public WidgetResizeDriver()
    {
        timer = new DispatcherTimer(DispatcherPriority.Input);
        timer.Interval = TimeSpan.FromMilliseconds(16);
        timer.Tick += OnTick;
    }

    public static int[] CalculateBounds(int[] initial, string edge, int dx, int dy, int minWidth, int minHeight)
    {
        if (initial == null || initial.Length != 4) throw new ArgumentException("initial");
        int left = initial[0], top = initial[1], width = initial[2], height = initial[3];
        if (edge.Contains("left")) { width = Math.Max(minWidth, width - dx); left += initial[2] - width; }
        else if (edge.Contains("right")) width = Math.Max(minWidth, width + dx);
        if (edge.Contains("top")) { height = Math.Max(minHeight, height - dy); top += initial[3] - height; }
        else if (edge.Contains("bottom")) height = Math.Max(minHeight, height + dy);
        return new int[] { left, top, width, height };
    }

    public bool Start(Window window, string edge)
    {
        if (IsActive) return false;
        HwndSource source = (HwndSource)PresentationSource.FromVisual(window);
        Rect bounds;
        if (source == null || !GetPhysicalCursorPos(out cursorStart) ||
            !GetWindowRect(source.Handle, out bounds)) return false;
        handle = source.Handle;
        this.edge = edge;
        start = new int[] { bounds.Left, bounds.Top, bounds.Right - bounds.Left, bounds.Bottom - bounds.Top };
        Matrix matrix = source.CompositionTarget.TransformToDevice;
        minWidth = Math.Max(1, (int)Math.Ceiling(window.MinWidth * matrix.M11));
        minHeight = Math.Max(1, (int)Math.Ceiling(window.MinHeight * matrix.M22));
        lastCursor = cursorStart;
        UpdateCount = 0;
        SetCapture(handle);
        if (GetCapture() != handle) return false;
        IsActive = true;
        timer.Start();
        return true;
    }

    private void ApplyCursor()
    {
        Point cursor;
        if (!GetPhysicalCursorPos(out cursor) || (cursor.X == lastCursor.X && cursor.Y == lastCursor.Y)) return;
        int[] bounds = CalculateBounds(start, edge, cursor.X - cursorStart.X, cursor.Y - cursorStart.Y, minWidth, minHeight);
        if (!SetWindowPos(handle, IntPtr.Zero, bounds[0], bounds[1], bounds[2], bounds[3], 0x0004 | 0x0010))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        lastCursor = cursor;
        UpdateCount++;
    }

    private void OnTick(object sender, EventArgs args)
    {
        if (!IsActive) { timer.Stop(); return; }
        if ((GetAsyncKeyState(0x1B) & 0x8000) != 0) { Cancel(); return; }
        if ((GetAsyncKeyState(1) & 0x8000) == 0 || GetCapture() != handle) { Stop(); return; }
        try { ApplyCursor(); }
        catch { Stop(); throw; }
    }

    public void Stop()
    {
        Finish(true);
    }

    public void Cancel()
    {
        if (!IsActive) return;
        try { SetWindowPos(handle, IntPtr.Zero, start[0], start[1], start[2], start[3], 0x0004 | 0x0010); }
        finally { Finish(false); }
    }

    private void Finish(bool sampleLastCursor)
    {
        if (!IsActive) return;
        timer.Stop();
        try { if (sampleLastCursor && GetCapture() == handle) ApplyCursor(); }
        finally
        {
            IsActive = false;
            if (GetCapture() == handle) ReleaseCapture();
            EventHandler completed = Completed;
            if (completed != null) completed(this, EventArgs.Empty);
        }
    }

    public void Dispose()
    {
        timer.Stop();
        IsActive = false;
        if (GetCapture() == handle) ReleaseCapture();
        timer.Tick -= OnTick;
        Completed = null;
    }
}
