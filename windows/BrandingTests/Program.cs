using PoFig;

internal static class BrandingTests
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        using var image = AppIcon.Image.ToBitmap();
        int red = 0;
        for (int y = 0; y < image.Height; y++) for (int x = 0; x < image.Width; x++)
        {
            var color = image.GetPixel(x, y);
            if (color.A > 128 && color.R > color.G * 1.2 && color.R > color.B * 1.2) red++;
        }
        Check(red > image.Width * image.Height / 20, "The embedded icon must be the red product icon, not the system placeholder");
        using var owner = new Form();
        AppIcon.Apply(owner);
        Check(owner.Icon != null, "Native windows must receive the product icon");
        for (int index = 0; index < 3; index++)
        {
            var accept = index == 0 ? TaskDialogButton.OK : TaskDialogButton.Yes;
            var cancel = index == 0 ? null : TaskDialogButton.No;
            var page = AppDialog.CreatePage("PoFig branding test", "PoFig", accept, cancel, defaultAccept: index != 2);
            Check(page.Icon?.IconHandle is { } handle && handle != IntPtr.Zero, "Dialogs must use a custom product icon handle");
            if (index == 2) Check(page.DefaultButton == cancel, "Destructive confirmations must default to cancellation");
            var click = index == 2 ? cancel! : accept;
            page.Created += (_, _) => click.PerformClick();
            using var watchdog = new CancellationTokenSource();
            _ = Task.Run(async () => { try { await Task.Delay(15000, watchdog.Token); Environment.FailFast("Native branding dialog did not close"); } catch (OperationCanceledException) { } });
            try { Check(AppDialog.Present(owner, page) == click, "Native confirmation must return the clicked button"); }
            finally { watchdog.Cancel(); }
        }
        Console.WriteLine("Windows branding: embedded product icon, window icon, native dialogs, confirmation and cancellation verified");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
