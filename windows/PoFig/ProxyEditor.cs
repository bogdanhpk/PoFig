namespace PoFig;

internal sealed class ProxyEditor : Form
{
    private readonly TextBox nameField = new(), hostField = new(), portField = new(), userField = new(), passwordField = new() { UseSystemPasswordChar = true };
    private readonly RadioButton[] protocols = [new() { Text = "HTTP" }, new() { Text = "HTTPS" }, new() { Text = "SOCKS5" }];
    private readonly Label error = new() { AutoSize = true, ForeColor = Color.Firebrick, MaximumSize = new Size(510, 60) };
    public ProxyEditor(ProxyProfile original, string password, Action<ProxyProfile, string> save)
    {
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Text = original.Name.Length == 0 ? "Новый прокси" : "Изменить прокси";
        ClientSize = new Size(610, 410); AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        nameField.Text = original.Name; hostField.Text = original.Host; portField.Text = original.Port.ToString();
        userField.Text = original.Username; passwordField.Text = password;
        hostField.PlaceholderText = "proxy.example.com";
        userField.PlaceholderText = passwordField.PlaceholderText = "Необязательно";
        var protocolRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Dock = DockStyle.Fill, Margin = Padding.Empty };
        foreach (var radio in protocols)
        {
            radio.Appearance = Appearance.Button; radio.TextAlign = ContentAlignment.MiddleCenter;
            radio.Size = new Size(118, 28); radio.Margin = new Padding(0, 0, 4, 0);
            radio.Checked = string.Equals(radio.Text, original.Protocol, StringComparison.OrdinalIgnoreCase);
            protocolRow.Controls.Add(radio);
        }
        var grid = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, RowCount = 6, Padding = new Padding(26, 14, 26, 0) };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130)); grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Control[] fields = [nameField, protocolRow, hostField, portField, userField, passwordField];
        string[] titles = ["Название", "Протокол", "Сервер", "Порт", "Пользователь", "Пароль"];
        for (int i = 0; i < fields.Length; i++)
        {
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
            var label = new Label { Text = titles[i], TextAlign = ContentAlignment.MiddleRight, Dock = DockStyle.Fill, Margin = new Padding(0, 0, 14, 10) };
            fields[i].Dock = DockStyle.Fill; fields[i].Margin = new Padding(0, 0, 0, 10);
            fields[i].AccessibleName = titles[i]; fields[i].TabIndex = i;
            grid.Controls.Add(label, 0, i); grid.Controls.Add(fields[i], 1, i);
        }
        var heading = new Label { Text = Text, Font = new Font(SystemFonts.MessageBoxFont!.FontFamily, 19, FontStyle.Bold), Dock = DockStyle.Top, Height = 54, Padding = new Padding(26, 18, 0, 0) };
        var cancel = new Button { Text = "Отмена", AutoSize = true, DialogResult = DialogResult.Cancel };
        var accept = new Button { Text = "Сохранить", AutoSize = true };
        accept.Click += (_, _) =>
        {
            try
            {
                var profile = original with { Name = nameField.Text.Trim(), Host = hostField.Text.Trim().Trim('[', ']'),
                    Port = int.TryParse(portField.Text, out int port) ? port : 0, Username = userField.Text,
                    Protocol = protocols.First(p => p.Checked).Text.ToLowerInvariant() };
                profile.Validate(passwordField.Text);
                save(profile, passwordField.Text); DialogResult = DialogResult.OK; Close();
            }
            catch (Exception ex) { error.Text = ex.Message; }
        };
        var actions = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Bottom, Height = 54, Padding = new Padding(0, 8, 26, 0) };
        actions.Controls.AddRange([accept, cancel]);
        error.Dock = DockStyle.Fill; error.Padding = new Padding(26, 0, 26, 0);
        Controls.Add(error); Controls.Add(grid); Controls.Add(heading); Controls.Add(actions);
        AcceptButton = accept; CancelButton = cancel;
    }
}
