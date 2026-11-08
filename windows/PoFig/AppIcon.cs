namespace PoFig;

internal static class AppIcon
{
    private static readonly Lazy<Icon> icon = new(() =>
    {
        using var stream = typeof(AppIcon).Assembly.GetManifestResourceStream("PoFig.ProductIcon")
            ?? throw new InvalidOperationException("Не удалось прочитать иконку PoFig.");
        using var loaded = new Icon(stream, new Size(256, 256));
        return (Icon)loaded.Clone();
    });

    public static Icon Image => icon.Value;

    public static void Apply(Form form) => form.Icon = Image;
}

internal static class AppDialog
{
    internal static TaskDialogPage CreatePage(string text, string caption, TaskDialogButton accept,
        TaskDialogButton? cancel = null, bool defaultAccept = true)
    {
        var page = new TaskDialogPage
        {
            Caption = caption,
            Text = text,
            Icon = new TaskDialogIcon(AppIcon.Image),
            AllowCancel = true,
            SizeToContent = true,
            DefaultButton = defaultAccept || cancel == null ? accept : cancel
        };
        page.Buttons.Add(accept);
        if (cancel != null) page.Buttons.Add(cancel);
        return page;
    }

    internal static TaskDialogButton Present(IWin32Window? owner, TaskDialogPage page)
    {
        try { return owner == null ? TaskDialog.ShowDialog(page) : TaskDialog.ShowDialog(owner, page); }
        finally { page.Icon?.Dispose(); }
    }

    public static void Show(string text, string caption = "PoFig", IWin32Window? owner = null) =>
        Present(owner, CreatePage(text, caption, TaskDialogButton.OK));

    public static bool Confirm(string text, string caption, IWin32Window owner, bool defaultAccept = true)
    {
        var accept = TaskDialogButton.Yes;
        var page = CreatePage(text, caption, accept, TaskDialogButton.No, defaultAccept);
        return Present(owner, page) == accept;
    }
}
