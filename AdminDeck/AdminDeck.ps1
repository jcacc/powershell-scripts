<#
.SYNOPSIS
AdminDeck - a Windows GUI for the AdminDroid / o365reports PowerShell scripts in this repo.

.DESCRIPTION
Browse and search every script, fill in a form generated from the script's own param()
block, and run it in its own PowerShell console with the output landing in a per-script
folder. Output CSVs can be opened in a built-in grid viewer.

Runs on stock Windows PowerShell 5.1 (WPF). Start it with AdminDeck.cmd, or:
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\AdminDeck\AdminDeck.ps1

.PARAMETER RepoRoot
Folder holding the scripts. Defaults to the parent of this file's folder.

.PARAMETER CreateShortcut
Creates an "AdminDeck" Start Menu shortcut and exits.

.PARAMETER RenderTo
Testing aid: builds the window off-screen, renders it to this PNG and exits.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$CreateShortcut,
    [string]$RenderTo,
    [string]$RenderSelect,
    [ValidateSet('Run', 'Outputs', 'Source')][string]$RenderTab = 'Run',
    [string]$RenderSearch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $here }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

# ---------------------------------------------------------------- bootstrap
if ($CreateShortcut) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'AdminDeck.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $MyInvocation.MyCommand.Path
    $lnk.WorkingDirectory = $RepoRoot
    $lnk.IconLocation = (Join-Path $PSHOME 'powershell.exe') + ',0'
    $lnk.Description = 'AdminDeck - run AdminDroid PowerShell scripts'
    $lnk.Save()
    Write-Host "Created $lnkPath"
    return
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $MyInvocation.MyCommand.Path, '-RepoRoot', $RepoRoot)
    Start-Process -FilePath $exe -ArgumentList $relaunch
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic
Import-Module (Join-Path $here 'AdminDeck.Catalog.psm1') -Force

$script:AppDir = Join-Path $env:APPDATA 'AdminDeck'
$script:SettingsPath = Join-Path $script:AppDir 'settings.json'
$script:ErrorLog = Join-Path $script:AppDir 'error.log'
if (-not (Test-Path -LiteralPath $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir | Out-Null }

$script:AuthPattern = '(?i)^(TenantId|TenantName|ClientId|AppId|CertificateThumb[Pp]rint|Thumbprint|Organization|UserName|Password|AdminName|AdminPass\w*|ClientSecret|CreateSession|Credential|MFA)$'
$script:ProfileKeys = @('TenantId', 'TenantName', 'Organization', 'ClientId', 'AppId', 'CertificateThumbprint', 'UserName', 'AdminName')
$script:Dot = ' ' + [char]0x00B7 + ' '
$script:PwshPath = $null
$pw = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pw) { $script:PwshPath = $pw.Source }
$script:WinPSPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ---------------------------------------------------------------- settings
function ConvertTo-AdHashtable($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-AdHashtable $p.Value }
        return $h
    }
    if ($obj -is [array]) { return , @($obj | ForEach-Object { ConvertTo-AdHashtable $_ }) }
    $obj
}

function Get-AdSettings {
    $s = @{}
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try { $s = ConvertTo-AdHashtable (Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json) } catch { $s = @{} }
    }
    if (-not $s) { $s = @{} }
    $defaults = @{
        OutputRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AdminDeck Reports'
        Shell = 'powershell'; KeepOpen = $true; Transcript = $false
        Favorites = @(); LastValues = @{}; Profile = @{}
    }
    foreach ($k in $defaults.Keys) { if (-not $s.ContainsKey($k) -or $null -eq $s[$k]) { $s[$k] = $defaults[$k] } }
    $s.Favorites = @($s.Favorites)
    $s
}

function Save-AdSettings {
    try {
        $script:Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch { Write-AdError $_ }
}

function Write-AdError($err) {
    try { Add-Content -LiteralPath $script:ErrorLog -Value ("[{0:u}] {1}`r`n{2}" -f (Get-Date), $err, $err.ScriptStackTrace) } catch {}
}

function Show-AdError($err) {
    Write-AdError $err
    [void][Windows.MessageBox]::Show("$err", 'AdminDeck', 'OK', 'Error')
}

$script:Settings = Get-AdSettings

# ---------------------------------------------------------------- XAML
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AdminDeck" Width="1320" Height="860" MinWidth="1000" MinHeight="620"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        Background="#F4F5F7" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#2563EB"/>
    <SolidColorBrush x:Key="Muted" Color="#6B7280"/>
    <SolidColorBrush x:Key="Line" Color="#E2E5EA"/>
    <Style TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#CBD0D8"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="BorderBrush" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,7"/>
    </Style>
    <Style x:Key="Bar" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2B3445"/>
      <Setter Property="BorderBrush" Value="#3B4659"/>
      <Setter Property="Foreground" Value="#E5E7EB"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
    </Style>
    <Style x:Key="Link" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Padding" Value="9,3"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="5,4"/>
      <Setter Property="BorderBrush" Value="#CBD0D8"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Padding" Value="5,4"/>
      <Setter Property="BorderBrush" Value="#CBD0D8"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Padding" Value="6,4"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Padding" Value="14,6"/>
    </Style>
  </Window.Resources>

  <DockPanel x:Name="Root" Background="#F4F5F7">
    <!-- top bar -->
    <Border DockPanel.Dock="Top" Background="#1C2433" Padding="18,11">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Background="#2563EB" CornerRadius="6" Width="30" Height="30" Margin="0,0,10,0">
            <TextBlock Text="&gt;_" Foreground="White" FontFamily="Consolas" FontWeight="Bold" FontSize="14"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="AdminDeck" Foreground="White" FontSize="17" FontWeight="SemiBold"/>
            <TextBlock x:Name="RepoText" Foreground="#9CA3AF" FontSize="11.5"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="ProfileButton" Style="{StaticResource Bar}" Content="Connection profile"/>
          <Button x:Name="ModulesButton" Style="{StaticResource Bar}" Content="Modules"/>
          <Button x:Name="UnblockButton" Style="{StaticResource Bar}" Content="Unblock scripts"/>
          <Button x:Name="ReportsButton" Style="{StaticResource Bar}" Content="Reports folder"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- status bar -->
    <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="14,5">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="StatusText" Foreground="{StaticResource Muted}" FontSize="12" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="ModuleStatusText" Grid.Column="1" Foreground="{StaticResource Muted}" FontSize="12"/>
      </Grid>
    </Border>

    <Grid Margin="14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="370" MinWidth="280"/>
        <ColumnDefinition Width="10"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- left: script browser -->
      <Border Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="12,12,12,6">
            <Grid>
              <TextBox x:Name="SearchBox" Padding="8,6"/>
              <TextBlock x:Name="SearchHint" Text="Search 180+ scripts (name, description, keywords)" IsHitTestVisible="False"
                         Foreground="#9CA3AF" Margin="11,0,0,0" VerticalAlignment="Center"/>
            </Grid>
            <Grid Margin="0,8,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <ComboBox x:Name="AreaFilter"/>
              <ComboBox x:Name="CategoryFilter" Grid.Column="2"/>
            </Grid>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <CheckBox x:Name="FavOnly" Content="Favorites" Margin="0,0,14,0"/>
              <CheckBox x:Name="ReadOnlyOnly" Content="Read-only reports only"/>
            </StackPanel>
            <TextBlock x:Name="CountText" Foreground="{StaticResource Muted}" FontSize="11.5" Margin="0,8,0,0"/>
          </StackPanel>
          <ListBox x:Name="ScriptList" BorderThickness="0" Margin="4,0,4,6" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   VirtualizingPanel.IsVirtualizing="True">
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                <Setter Property="Padding" Value="8,6"/>
              </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" ToolTip="{Binding Name}"/>
                    <TextBlock Text="{Binding Subtitle}" Foreground="#6B7280" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="6,0,0,0">
                    <Border Background="#FEF3C7" CornerRadius="3" Padding="5,1" Visibility="{Binding WarnVis}" ToolTip="May change tenant settings or data">
                      <TextBlock Text="changes" FontSize="10.5" Foreground="#92400E"/>
                    </Border>
                    <TextBlock Text="{Binding Star}" Foreground="#F59E0B" FontSize="14" Margin="5,0,0,0"/>
                  </StackPanel>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </DockPanel>
      </Border>

      <GridSplitter Grid.Column="1" Width="10" HorizontalAlignment="Stretch" Background="Transparent"/>

      <!-- right: details -->
      <Grid Grid.Column="2">
        <TextBlock x:Name="EmptyText" Text="Select a script on the left." Foreground="{StaticResource Muted}" FontSize="15"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <DockPanel x:Name="DetailPanel" Visibility="Collapsed">
          <Border DockPanel.Dock="Top" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="18,14" Margin="0,0,0,10">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="TitleText" FontSize="19" FontWeight="SemiBold" TextWrapping="Wrap" Foreground="#111827"/>
                <Button x:Name="FavButton" Grid.Column="1" Style="{StaticResource Link}" VerticalAlignment="Top" Margin="10,0,0,0"/>
              </Grid>
              <TextBlock x:Name="DescText" TextWrapping="Wrap" Foreground="#374151" Margin="0,6,0,0"/>
              <WrapPanel x:Name="BadgePanel" Margin="0,10,0,0"/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="DocsButton" Style="{StaticResource Link}" Content="Documentation"/>
                <Button x:Name="ReadmeButton" Style="{StaticResource Link}" Content="README"/>
                <Button x:Name="FolderButton" Style="{StaticResource Link}" Content="Script folder"/>
                <Button x:Name="EditButton" Style="{StaticResource Link}" Content="Open in editor"/>
              </StackPanel>
              <Expander x:Name="HighlightsExpander" Header="Script highlights" Margin="0,10,0,0" Foreground="#374151">
                <TextBlock x:Name="HighlightsText" TextWrapping="Wrap" Foreground="#4B5563" Margin="20,6,0,0" LineHeight="20"/>
              </Expander>
            </StackPanel>
          </Border>

          <TabControl x:Name="Tabs" Background="White" BorderBrush="{StaticResource Line}" Padding="0">
            <TabItem x:Name="RunTab" Header="Run">
              <DockPanel>
                <Border DockPanel.Dock="Bottom" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Background="#FAFBFC" Padding="16,12">
                  <StackPanel>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Command" FontWeight="SemiBold" Foreground="#374151" FontSize="12"/>
                      <Button x:Name="CopyButton" Grid.Column="1" Style="{StaticResource Link}" Margin="0" Content="Copy"/>
                    </Grid>
                    <TextBox x:Name="PreviewBox" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"
                             Height="44" VerticalScrollBarVisibility="Auto" Margin="0,5,0,0" Background="#F3F4F6" VerticalContentAlignment="Top"/>
                    <TextBlock x:Name="ErrorText" Foreground="#B91C1C" FontSize="12" TextWrapping="Wrap" Margin="0,5,0,0"/>
                    <DockPanel Margin="0,8,0,0">
                      <TextBlock DockPanel.Dock="Left" Text="Output to" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,0,8,0"/>
                      <Button x:Name="OutBrowse" DockPanel.Dock="Right" Style="{StaticResource Link}" Margin="6,0,0,0" Content="Browse..."/>
                      <TextBox x:Name="OutRootBox" ToolTip="Each script gets its own subfolder here; the script runs with this as its current folder"/>
                    </DockPanel>
                    <Grid Margin="0,8,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <WrapPanel VerticalAlignment="Center">
                        <ComboBox x:Name="ShellCombo" Width="200" Margin="0,0,14,0"/>
                        <CheckBox x:Name="KeepOpenCheck" Content="Keep window open" Margin="0,0,14,0" VerticalAlignment="Center"/>
                        <CheckBox x:Name="TranscriptCheck" Content="Save transcript" VerticalAlignment="Center"/>
                      </WrapPanel>
                      <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="10,0,0,0">
                        <Button x:Name="ResetButton" Content="Reset" Margin="0,0,8,0"/>
                        <Button x:Name="RunButton" Style="{StaticResource Primary}" Content="Run script"/>
                      </StackPanel>
                    </Grid>
                  </StackPanel>
                </Border>
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18,14,18,10">
                  <StackPanel>
                    <TextBlock x:Name="SetsText" Foreground="#92400E" TextWrapping="Wrap" Margin="0,0,0,10" Visibility="Collapsed"/>
                    <Grid x:Name="FormGrid"/>
                  </StackPanel>
                </ScrollViewer>
              </DockPanel>
            </TabItem>
            <TabItem x:Name="OutputsTab" Header="Output files">
              <DockPanel Margin="12">
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="OutViewButton" Style="{StaticResource Link}" Content="View in grid"/>
                  <Button x:Name="OutOpenButton" Style="{StaticResource Link}" Content="Open"/>
                  <Button x:Name="OutShowButton" Style="{StaticResource Link}" Content="Show in Explorer"/>
                  <Button x:Name="OutFolderButton" Style="{StaticResource Link}" Content="Open output folder"/>
                  <TextBlock x:Name="OutDirText" Foreground="{StaticResource Muted}" VerticalAlignment="Center" FontSize="12" Margin="6,0,0,0"/>
                </StackPanel>
                <TextBlock x:Name="OutEmptyText" DockPanel.Dock="Top" Foreground="{StaticResource Muted}" Margin="2,0,0,8"
                           Text="Nothing yet. Files the script writes show up here (refreshes automatically)." />
                <ListView x:Name="OutputList" BorderBrush="{StaticResource Line}">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="File" Width="320" DisplayMemberBinding="{Binding Name}"/>
                      <GridViewColumn Header="Modified" Width="150" DisplayMemberBinding="{Binding Modified}"/>
                      <GridViewColumn Header="Size" Width="90" DisplayMemberBinding="{Binding Size}"/>
                      <GridViewColumn Header="Location" Width="120" DisplayMemberBinding="{Binding Where}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
              </DockPanel>
            </TabItem>
            <TabItem x:Name="SourceTab" Header="Source">
              <TextBox x:Name="SourceBox" IsReadOnly="True" FontFamily="Consolas" FontSize="12" BorderThickness="0"
                       HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top" Padding="10"/>
            </TabItem>
          </TabControl>
        </DockPanel>
      </Grid>
    </Grid>
  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in ([regex]::Matches($xaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })) { $ui[$n] = $window.FindName($n) }

function New-Brush([string]$hex) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }

# ---------------------------------------------------------------- catalog
$script:Catalog = @(Get-AdScriptCatalog -RepoRoot $RepoRoot | Sort-Object Name)
$script:ById = @{}
foreach ($s in $script:Catalog) { $script:ById[$s.Id] = $s }
$script:ParamCache = @{}
$script:Current = $null
$script:CurrentInfo = $null
$script:Fields = [ordered]@{}
$script:ModuleStatus = $null
$script:OutputSignature = ''
$script:Loading = $false
$script:ModuleJob = $null
$script:ModulesWindowList = $null
$script:ExtraBox = $null
$script:SourceLoadedFor = $null

$ui.RepoText.Text = "$($script:Catalog.Count) scripts$($script:Dot)$RepoRoot"
$ui.AreaFilter.Items.Add('All areas') | Out-Null
foreach ($a in ($script:Catalog | Select-Object -ExpandProperty Area -Unique | Sort-Object)) { $ui.AreaFilter.Items.Add($a) | Out-Null }
$ui.AreaFilter.SelectedIndex = 0
$ui.CategoryFilter.Items.Add('All types') | Out-Null
foreach ($c in ($script:Catalog | Select-Object -ExpandProperty Category -Unique | Sort-Object)) { $ui.CategoryFilter.Items.Add($c) | Out-Null }
$ui.CategoryFilter.SelectedIndex = 0

function Update-ScriptList {
    $q = $ui.SearchBox.Text.Trim().ToLowerInvariant()
    $terms = @($q -split '\s+' | Where-Object { $_ })
    $area = [string]$ui.AreaFilter.SelectedItem
    $cat = [string]$ui.CategoryFilter.SelectedItem
    $favs = @($script:Settings.Favorites)
    $selectedId = $null
    if ($ui.ScriptList.SelectedItem) { $selectedId = $ui.ScriptList.SelectedItem.Id }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($s in $script:Catalog) {
        if ($area -ne 'All areas' -and $s.Area -ne $area) { continue }
        if ($cat -ne 'All types' -and $s.Category -ne $cat) { continue }
        if ($ui.FavOnly.IsChecked -and $favs -notcontains $s.Id) { continue }
        if ($ui.ReadOnlyOnly.IsChecked -and $s.Modifies) { continue }
        $ok = $true
        foreach ($t in $terms) { if (-not $s.SearchText.Contains($t)) { $ok = $false; break } }
        if (-not $ok) { continue }
        $sub = $s.Area + $script:Dot + $s.Category
        if ($s.Services.Count) { $sub += $script:Dot + ($s.Services -join ', ') }
        $items.Add([pscustomobject]@{
            Id = $s.Id; Name = $s.Name; Subtitle = $sub
            Star = $(if ($favs -contains $s.Id) { [string][char]0x2605 } else { '' })
            WarnVis = $(if ($s.Modifies) { 'Visible' } else { 'Collapsed' })
        })
    }
    $script:Loading = $true
    $ui.ScriptList.ItemsSource = $items.ToArray()
    if ($selectedId) {
        foreach ($it in $items) { if ($it.Id -eq $selectedId) { $ui.ScriptList.SelectedItem = $it; break } }
    }
    $script:Loading = $false
    $ui.CountText.Text = "Showing $($items.Count) of $($script:Catalog.Count)"
}

# ---------------------------------------------------------------- form
function New-AdBadge([string]$text, [string]$bg, [string]$fg, [string]$tip) {
    $b = New-Object Windows.Controls.Border
    $b.Background = New-Brush $bg; $b.CornerRadius = 4; $b.Padding = '7,2'; $b.Margin = '0,0,6,4'
    if ($tip) { $b.ToolTip = $tip }
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = 11.5; $t.Foreground = New-Brush $fg
    $b.Child = $t
    $b
}

function Update-Badges {
    $s = $script:Current
    $ui.BadgePanel.Children.Clear()
    [void]$ui.BadgePanel.Children.Add((New-AdBadge $s.Area '#E0E7FF' '#3730A3'))
    [void]$ui.BadgePanel.Children.Add((New-AdBadge $s.Category '#E5E7EB' '#374151'))
    if ($s.Modifies) { [void]$ui.BadgePanel.Children.Add((New-AdBadge 'May change tenant' '#FEF3C7' '#92400E' 'Contains cmdlets that modify Microsoft 365 objects or is an automation script. You will be asked to confirm before it runs.')) }
    else { [void]$ui.BadgePanel.Children.Add((New-AdBadge 'Read-only' '#DCFCE7' '#166534')) }
    foreach ($m in $s.Modules) {
        $state = $null
        if ($script:ModuleStatus) { $state = $script:ModuleStatus[$m] }
        if ($null -eq $script:ModuleStatus) { [void]$ui.BadgePanel.Children.Add((New-AdBadge "$m (checking)" '#F3F4F6' '#6B7280')) }
        elseif ($state) { [void]$ui.BadgePanel.Children.Add((New-AdBadge "$m $state" '#DCFCE7' '#166534' 'Installed')) }
        else { [void]$ui.BadgePanel.Children.Add((New-AdBadge "$m missing" '#FEE2E2' '#991B1B' 'Not installed for this PowerShell. Most scripts offer to install it; or use Modules.')) }
    }
    if ($s.Version) { [void]$ui.BadgePanel.Children.Add((New-AdBadge "v$($s.Version)" '#F3F4F6' '#6B7280')) }
}

function Add-FormRow([Windows.Controls.Grid]$grid, $labelElement, $control) {
    $row = New-Object Windows.Controls.RowDefinition
    $row.Height = 'Auto'
    $grid.RowDefinitions.Add($row)
    $i = $grid.RowDefinitions.Count - 1
    if ($labelElement) {
        [Windows.Controls.Grid]::SetRow($labelElement, $i); [Windows.Controls.Grid]::SetColumn($labelElement, 0)
        [void]$grid.Children.Add($labelElement)
    }
    if ($control) {
        [Windows.Controls.Grid]::SetRow($control, $i)
        if ($labelElement) { [Windows.Controls.Grid]::SetColumn($control, 1) } else { [Windows.Controls.Grid]::SetColumnSpan($control, 2) }
        [void]$grid.Children.Add($control)
    }
}

function New-SectionHeader([string]$text, [string]$sub) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,6,0,10'
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.FontWeight = 'SemiBold'; $t.FontSize = 14; $t.Foreground = New-Brush '#111827'
    [void]$sp.Children.Add($t)
    if ($sub) {
        $s2 = New-Object Windows.Controls.TextBlock
        $s2.Text = $sub; $s2.Foreground = New-Brush '#6B7280'; $s2.FontSize = 12; $s2.TextWrapping = 'Wrap'
        [void]$sp.Children.Add($s2)
    }
    $line = New-Object Windows.Controls.Border
    $line.Height = 1; $line.Background = New-Brush '#E5E7EB'; $line.Margin = '0,6,0,0'
    [void]$sp.Children.Add($line)
    $sp
}

function New-FieldControl($p) {
    # Returns @{ Element = <what goes in the grid>; Field = <state used by Get/Set-FieldValue> }
    $field = @{ Param = $p; Kind = $p.Kind; Control = $null; Date = $null; Time = $null }
    $element = $null
    switch ($p.Kind) {
        'Switch' {
            $c = New-Object Windows.Controls.CheckBox
            $c.Content = 'Enabled'; $c.Foreground = New-Brush '#4B5563'
            $c.Add_Checked({ Update-Preview }); $c.Add_Unchecked({ Update-Preview })
            $field.Control = $c; $element = $c
        }
        { $_ -eq 'Choice' -or $_ -eq 'Bool' } {
            $c = New-Object Windows.Controls.ComboBox
            $c.MinWidth = 260; $c.HorizontalAlignment = 'Left'
            [void]$c.Items.Add('')
            $opts = if ($p.Kind -eq 'Bool') { @('True', 'False') } else { $p.Choices }
            foreach ($o in $opts) { [void]$c.Items.Add($o) }
            $c.SelectedIndex = 0
            $c.Add_SelectionChanged({ Update-Preview })
            $field.Control = $c; $element = $c
        }
        'Date' {
            $sp = New-Object Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $d = New-Object Windows.Controls.DatePicker
            $d.Width = 160; $d.SelectedDateFormat = 'Short'
            $d.Add_SelectedDateChanged({ Update-Preview })
            $t = New-Object Windows.Controls.TextBox
            $t.Width = 70; $t.Margin = '8,0,0,0'; $t.ToolTip = 'Optional time, 24h HH:mm'
            $t.Add_TextChanged({ Update-Preview })
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = 'time (optional)'; $lbl.Foreground = New-Brush '#9CA3AF'; $lbl.VerticalAlignment = 'Center'; $lbl.Margin = '6,0,0,0'; $lbl.FontSize = 12
            [void]$sp.Children.Add($d); [void]$sp.Children.Add($t); [void]$sp.Children.Add($lbl)
            $field.Date = $d; $field.Time = $t; $element = $sp
        }
        'Secret' {
            $c = New-Object Windows.Controls.PasswordBox
            $c.MaxWidth = 420; $c.HorizontalAlignment = 'Stretch'
            $c.Add_PasswordChanged({ Update-Preview })
            $field.Control = $c; $element = $c
        }
        'List' {
            $c = New-Object Windows.Controls.TextBox
            $c.AcceptsReturn = $true; $c.TextWrapping = 'Wrap'; $c.Height = 56; $c.VerticalContentAlignment = 'Top'
            $c.Add_TextChanged({ Update-Preview })
            $field.Control = $c; $element = $c
        }
        { $_ -eq 'File' -or $_ -eq 'Folder' } {
            $dp = New-Object Windows.Controls.DockPanel
            $b = New-Object Windows.Controls.Button
            $b.Content = 'Browse...'; $b.Padding = '10,3'; $b.Margin = '6,0,0,0'
            [Windows.Controls.DockPanel]::SetDock($b, 'Right')
            $c = New-Object Windows.Controls.TextBox
            $c.Add_TextChanged({ Update-Preview })
            $b.Tag = @{ Box = $c; Kind = $p.Kind }
            $b.Add_Click({ Invoke-Browse $this.Tag })
            [void]$dp.Children.Add($b); [void]$dp.Children.Add($c)
            $field.Control = $c; $element = $dp
        }
        default {
            $c = New-Object Windows.Controls.TextBox
            if ($p.Kind -eq 'Number') { $c.Width = 120; $c.HorizontalAlignment = 'Left' }
            $c.Add_TextChanged({ Update-Preview })
            $field.Control = $c; $element = $c
        }
    }
    @{ Element = $element; Field = $field }
}

function Invoke-Browse($tag) {
    try {
        if ($tag.Kind -eq 'Folder') {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($tag.Box.Text -and (Test-Path -LiteralPath $tag.Box.Text)) { $dlg.SelectedPath = $tag.Box.Text }
            if ($dlg.ShowDialog() -eq 'OK') { $tag.Box.Text = $dlg.SelectedPath }
        } else {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'CSV / text (*.csv;*.txt)|*.csv;*.txt|HTML (*.html;*.htm)|*.html;*.htm|All files (*.*)|*.*'
            $dlg.CheckFileExists = $false
            if ($dlg.ShowDialog($window)) { $tag.Box.Text = $dlg.FileName }
        }
    } catch { Show-AdError $_ }
}

function Get-FieldValue($f) {
    switch ($f.Kind) {
        'Switch' { return [bool]$f.Control.IsChecked }
        'Choice' { return [string]$f.Control.SelectedItem }
        'Bool' { return [string]$f.Control.SelectedItem }
        'Secret' { return $f.Control.Password }
        'Date' {
            if (-not $f.Date.SelectedDate) { return '' }
            $v = $f.Date.SelectedDate.ToString('yyyy-MM-dd')
            $t = $f.Time.Text.Trim()
            if ($t) { $v += ' ' + $t }
            return $v
        }
        default { return $f.Control.Text }
    }
}

function Set-FieldValue($f, $v) {
    if ($null -eq $v) { return }
    switch ($f.Kind) {
        'Switch' { $f.Control.IsChecked = [bool]$v }
        { $_ -eq 'Choice' -or $_ -eq 'Bool' } { if ($f.Control.Items.Contains([string]$v)) { $f.Control.SelectedItem = [string]$v } }
        'Secret' { }
        'Date' {
            $d = [datetime]::MinValue
            if ([datetime]::TryParse([string]$v, [ref]$d)) {
                $f.Date.SelectedDate = $d.Date
                if ($d.TimeOfDay.TotalMinutes -gt 0) { $f.Time.Text = $d.ToString('HH:mm') }
            }
        }
        default { $f.Control.Text = [string]$v }
    }
}

function Build-Form {
    $grid = $ui.FormGrid
    $grid.Children.Clear(); $grid.RowDefinitions.Clear(); $grid.ColumnDefinitions.Clear()
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '210'
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1)
    $script:Fields = [ordered]@{}
    $info = $script:CurrentInfo

    if ($info.ParseErrors.Count) {
        $warn = New-Object Windows.Controls.TextBlock
        $warn.Text = "PowerShell could not fully parse this script, so the form may be incomplete:`n" + ($info.ParseErrors | Select-Object -First 3 | Out-String)
        $warn.Foreground = New-Brush '#B91C1C'; $warn.TextWrapping = 'Wrap'; $warn.Margin = '0,0,0,10'
        Add-FormRow $grid $null $warn
    }

    $main = @($info.Parameters | Where-Object { $_.Name -notmatch $script:AuthPattern })
    $auth = @($info.Parameters | Where-Object { $_.Name -match $script:AuthPattern })

    if (-not $info.Parameters.Count) {
        $none = New-Object Windows.Controls.TextBlock
        $none.Text = 'This script takes no parameters. Settings, if any, are edited inside the script (Open in editor).'
        $none.Foreground = New-Brush '#6B7280'; $none.TextWrapping = 'Wrap'; $none.Margin = '0,0,0,10'
        Add-FormRow $grid $null $none
    }
    if ($main.Count) { Add-FormRow $grid $null (New-SectionHeader 'Parameters' 'Leave anything blank to use the script default; many scripts prompt for what they need.') }
    foreach ($p in $main) { Add-ParamRow $grid $p }
    if ($auth.Count) {
        Add-FormRow $grid $null (New-SectionHeader 'Sign-in' 'Leave blank for interactive (MFA-capable) sign-in. Fill TenantId / ClientId / CertificateThumbprint for unattended certificate auth. Saved values come from Connection profile.')
        foreach ($p in $auth) { Add-ParamRow $grid $p }
    }

    Add-FormRow $grid $null (New-SectionHeader 'Advanced' $null)
    $extraLabel = New-FieldLabel 'Extra arguments' $false 'Appended to the command as-is, e.g. -Verbose'
    $extra = New-Object Windows.Controls.TextBox
    $extra.FontFamily = 'Consolas'
    $extra.Add_TextChanged({ Update-Preview })
    $extra.Margin = '0,0,0,12'
    $script:ExtraBox = $extra
    Add-FormRow $grid $extraLabel $extra

    if ($info.ParameterSets.Count) {
        $ui.SetsText.Text = 'This script has alternative parameter sets (' + ($info.ParameterSets -join ', ') + '). Fill only the fields for the one you want; see the hint under each field.'
        $ui.SetsText.Visibility = 'Visible'
    } else { $ui.SetsText.Visibility = 'Collapsed' }
}

function New-FieldLabel([string]$name, [bool]$required, [string]$tip) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,4,12,12'
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $name; $t.FontWeight = 'SemiBold'; $t.Foreground = New-Brush '#1F2937'; $t.TextWrapping = 'Wrap'
    if ($required) {
        $r = New-Object Windows.Documents.Run ' *'
        $r.Foreground = New-Brush '#DC2626'
        $t.Inlines.Add($r)
    }
    [void]$sp.Children.Add($t)
    if ($tip) {
        $s = New-Object Windows.Controls.TextBlock
        $s.Text = $tip; $s.Foreground = New-Brush '#9CA3AF'; $s.FontSize = 11.5; $s.TextWrapping = 'Wrap'
        [void]$sp.Children.Add($s)
    }
    $sp
}

function Add-ParamRow($grid, $p) {
    $typeLabel = switch ($p.Kind) {
        'Switch' { 'switch' } 'Date' { 'date' } 'Number' { 'number' } 'List' { 'list' } 'Secret' { 'secret, never saved' }
        'Choice' { 'choice' } 'File' { 'file path' } 'Folder' { 'folder' } 'Bool' { 'true / false' } default { 'text' }
    }
    $label = New-FieldLabel $p.Name $p.AlwaysRequired $typeLabel
    $built = New-FieldControl $p
    $wrap = New-Object Windows.Controls.StackPanel
    $wrap.Margin = '0,0,0,12'
    [void]$wrap.Children.Add($built.Element)
    $notes = New-Object System.Collections.Generic.List[string]
    if ($p.Hint) { $notes.Add($p.Hint) }
    if ($p.Default -and $p.Kind -ne 'Switch') { $notes.Add("Default: $($p.Default)") }
    if ($p.Kind -eq 'List') { $notes.Add('Separate values with commas or new lines.') }
    if ($p.ParameterSets.Count) { $notes.Add('Parameter set: ' + ($p.ParameterSets -join ', ')) }
    if ($p.MandatorySets.Count -and -not $p.AlwaysRequired) { $notes.Add('Required for: ' + (($p.MandatorySets | ForEach-Object { if ($_ -eq '*') { 'all sets' } else { $_ } }) -join ', ')) }
    if ($notes.Count) {
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = ($notes -join ('  ' + [char]0x2022 + '  '))
        $h.Foreground = New-Brush '#6B7280'; $h.FontSize = 12; $h.TextWrapping = 'Wrap'; $h.Margin = '1,4,0,0'
        [void]$wrap.Children.Add($h)
    }
    Add-FormRow $grid $label $wrap
    $script:Fields[$p.Name] = $built.Field
}

function Get-FormValues {
    $h = @{}
    foreach ($k in $script:Fields.Keys) { $h[$k] = Get-FieldValue $script:Fields[$k] }
    $h
}

function Get-CurrentInvocation {
    $extra = ''
    if ($script:ExtraBox) { $extra = $script:ExtraBox.Text }
    ConvertTo-AdInvocation -ScriptPath $script:Current.Path -Parameters $script:CurrentInfo.Parameters -Values (Get-FormValues) -ExtraArguments $extra
}

function Update-Preview {
    if ($script:Loading -or -not $script:Current) { return }
    try {
        $inv = Get-CurrentInvocation
        $ui.PreviewBox.Text = $inv.Display
        $ui.ErrorText.Text = ($inv.Errors -join '  ')
        $ui.ErrorText.Visibility = $(if ($inv.Errors.Count) { 'Visible' } else { 'Collapsed' })
    } catch { $ui.ErrorText.Text = "$_" }
}

function Restore-FormValues([switch]$Defaults) {
    $script:Loading = $true
    try {
        $last = @{}
        if (-not $Defaults -and $script:Settings.LastValues.ContainsKey($script:Current.Id)) { $last = $script:Settings.LastValues[$script:Current.Id] }
        $prof = $script:Settings.Profile
        foreach ($k in $script:Fields.Keys) {
            $f = $script:Fields[$k]
            if ($k -match $script:AuthPattern) {
                foreach ($pk in @($prof.Keys)) { if ($pk -eq $k -and $prof[$pk]) { Set-FieldValue $f $prof[$pk] } }
            } elseif ($last -and $last.ContainsKey($k)) {
                Set-FieldValue $f $last[$k]
            }
        }
    } finally { $script:Loading = $false }
    Update-Preview
}

function Save-FormValues {
    $vals = @{}
    foreach ($k in $script:Fields.Keys) {
        $f = $script:Fields[$k]
        if ($f.Kind -eq 'Secret' -or $k -match $script:AuthPattern) { continue }
        $v = Get-FieldValue $f
        if ($f.Kind -eq 'Switch') { if ($v) { $vals[$k] = $true } }
        elseif ("$v".Trim()) { $vals[$k] = $v }
    }
    $script:Settings.LastValues[$script:Current.Id] = $vals
}

# ---------------------------------------------------------------- selection
function Show-Script($id) {
    $s = $script:ById[$id]
    if (-not $s) { return }
    $script:Current = $s
    if (-not $script:ParamCache.ContainsKey($id)) { $script:ParamCache[$id] = Get-AdScriptParameters -Path $s.Path }
    $script:CurrentInfo = $script:ParamCache[$id]

    $ui.EmptyText.Visibility = 'Collapsed'
    $ui.DetailPanel.Visibility = 'Visible'
    $ui.TitleText.Text = $s.Title
    $ui.DescText.Text = $(if ($s.Description) { $s.Description } else { $s.Name })
    $ui.DocsButton.IsEnabled = [bool]$s.DocsUrl
    $ui.DocsButton.ToolTip = $s.DocsUrl
    $ui.ReadmeButton.IsEnabled = Test-Path -LiteralPath (Join-Path $s.Folder 'README.md')
    if ($s.Highlights.Count) {
        $ui.HighlightsExpander.Visibility = 'Visible'
        $ui.HighlightsText.Text = ($s.Highlights | ForEach-Object { [string][char]0x2022 + ' ' + $_ }) -join "`n"
    } else { $ui.HighlightsExpander.Visibility = 'Collapsed' }
    Update-FavButton
    Update-Badges

    # PnP.PowerShell 2.x needs PowerShell 7, so prefer pwsh for those when it exists.
    $wantPwsh = ($script:Settings.Shell -eq 'pwsh') -or ($s.Modules -contains 'PnP.PowerShell')
    if ($wantPwsh -and $script:PwshPath) { $ui.ShellCombo.SelectedIndex = 1 } else { $ui.ShellCombo.SelectedIndex = 0 }

    Build-Form
    Restore-FormValues
    $script:SourceLoadedFor = $null
    if ($ui.Tabs.SelectedItem -eq $ui.SourceTab) { Show-Source }
    $script:OutputSignature = ''
    Update-Outputs
    $ui.StatusText.Text = $s.Path
}

function Update-FavButton {
    if (-not $script:Current) { return }
    if (@($script:Settings.Favorites) -contains $script:Current.Id) { $ui.FavButton.Content = [string][char]0x2605 + ' Favorite' }
    else { $ui.FavButton.Content = [string][char]0x2606 + ' Add to favorites' }
}

function Show-Source {
    if (-not $script:Current -or $script:SourceLoadedFor -eq $script:Current.Id) { return }
    $ui.SourceBox.Text = [IO.File]::ReadAllText($script:Current.Path)
    $script:SourceLoadedFor = $script:Current.Id
}

# ---------------------------------------------------------------- run
function Get-OutputDir {
    $root = $ui.OutRootBox.Text.Trim()
    if (-not $root) { $root = $script:Settings.OutputRoot }
    $leaf = $script:Current.FolderName
    if ($script:Current.Folder.TrimEnd('\') -eq $RepoRoot.TrimEnd('\')) { $leaf = $script:Current.Name }
    Join-Path $root (Get-AdSafeFolderName $leaf)
}

function Get-SelectedShell {
    if ($ui.ShellCombo.SelectedIndex -eq 1 -and $script:PwshPath) { return $script:PwshPath }
    $script:WinPSPath
}

function Start-AdScript {
    if (-not $script:Current) { return }
    $inv = Get-CurrentInvocation
    if ($inv.Errors.Count) {
        [void][Windows.MessageBox]::Show(($inv.Errors -join "`n"), 'Fix these first', 'OK', 'Warning')
        return
    }
    if ($script:Current.Modifies) {
        $msg = "'$($script:Current.Name)' may change data or settings in your tenant.`n`nCommand:`n$($inv.Display)`n`nRun it?"
        if ([Windows.MessageBox]::Show($msg, 'Confirm', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    $outDir = Get-OutputDir
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    $launch = New-AdLaunchScript -Invocation $inv -Title $script:Current.Name -WorkingDirectory $outDir -Transcript:([bool]$ui.TranscriptCheck.IsChecked)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
    $argList = New-Object System.Collections.Generic.List[string]
    foreach ($a in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass')) { $argList.Add($a) }
    if ($ui.KeepOpenCheck.IsChecked) { $argList.Add('-NoExit') }
    $argList.Add('-EncodedCommand'); $argList.Add($encoded)

    # Secrets go to the child through its inherited environment, never the command line.
    $exe = Get-SelectedShell
    try {
        foreach ($k in $inv.Secrets.Keys) { [Environment]::SetEnvironmentVariable($k, $inv.Secrets[$k], 'Process') }
        $proc = Start-Process -FilePath $exe -ArgumentList $argList.ToArray() -WorkingDirectory $outDir -PassThru
    } finally {
        foreach ($k in $inv.Secrets.Keys) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
    }

    Save-FormValues
    $script:Settings.OutputRoot = $ui.OutRootBox.Text.Trim()
    $script:Settings.KeepOpen = [bool]$ui.KeepOpenCheck.IsChecked
    $script:Settings.Transcript = [bool]$ui.TranscriptCheck.IsChecked
    Save-AdSettings
    Add-Content -LiteralPath (Join-Path $script:AppDir 'history.log') -Value ("{0:u}`t{1}`t{2}" -f (Get-Date), $outDir, $inv.Display)
    $ui.StatusText.Text = "Started '$($script:Current.Name)' in a new $(Split-Path $exe -Leaf) window (PID $($proc.Id)). Output: $outDir"
}

# ---------------------------------------------------------------- outputs
function Format-Size([long]$b) {
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    "$b B"
}

function Update-Outputs {
    if (-not $script:Current) { return }
    $outDir = Get-OutputDir
    $ui.OutDirText.Text = $outDir
    $files = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $outDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $outDir -File -ErrorAction SilentlyContinue)) { $files.Add(@{ F = $f; Where = 'output folder' }) }
    }
    # Some scripts write next to themselves ($PSScriptRoot).
    foreach ($f in (Get-ChildItem -LiteralPath $script:Current.Folder -File -ErrorAction SilentlyContinue)) {
        if ($f.Extension -notmatch '^\.(csv|html?|xlsx|txt|log|json)$' -or $f.Name -like 'LicenseFriendlyName*' -or $f.Name -eq 'ScriptMetadata.csv') { continue }
        $files.Add(@{ F = $f; Where = 'script folder' })
    }
    $sorted = @($files | Sort-Object { $_.F.LastWriteTime } -Descending)
    $sig = ($sorted | ForEach-Object { $_.F.FullName + '|' + $_.F.LastWriteTime.Ticks + '|' + $_.F.Length }) -join ';'
    if ($sig -eq $script:OutputSignature) { return }
    $script:OutputSignature = $sig
    $selected = $null
    if ($ui.OutputList.SelectedItem) { $selected = $ui.OutputList.SelectedItem.FullName }
    $items = @($sorted | ForEach-Object {
        [pscustomobject]@{
            Name = $_.F.Name; FullName = $_.F.FullName; Where = $_.Where
            Modified = $_.F.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); Size = Format-Size $_.F.Length
        }
    })
    $ui.OutputList.ItemsSource = $items
    foreach ($it in $items) { if ($it.FullName -eq $selected) { $ui.OutputList.SelectedItem = $it } }
    $ui.OutEmptyText.Visibility = $(if ($items.Count) { 'Collapsed' } else { 'Visible' })
    $ui.OutputsTab.Header = $(if ($items.Count) { "Output files ($($items.Count))" } else { 'Output files' })
}

function Get-SelectedOutput {
    $it = $ui.OutputList.SelectedItem
    if (-not $it -and $ui.OutputList.Items.Count) { $it = $ui.OutputList.Items[0] }
    $it
}

function Show-CsvViewer([string]$path) {
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($path)
    $table = New-Object System.Data.DataTable
    try {
        $parser.TextFieldType = 'Delimited'; $parser.SetDelimiters(','); $parser.HasFieldsEnclosedInQuotes = $true
        if ($parser.EndOfData) { throw 'The file is empty.' }
        $headers = $parser.ReadFields()
        if ($headers.Count -and $headers[0] -like '#TYPE*') { $headers = $parser.ReadFields() }
        $seen = @{}
        foreach ($h in $headers) {
            $name = if ($h) { $h } else { 'Column' }
            $n = $name; $i = 2
            while ($seen.ContainsKey($n)) { $n = "$name ($i)"; $i++ }
            $seen[$n] = 1
            [void]$table.Columns.Add($n, [string])
        }
        $table.BeginLoadData()
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            if ($fields.Count -gt $table.Columns.Count) { $fields = $fields[0..($table.Columns.Count - 1)] }
            [void]$table.Rows.Add([object[]]$fields)
        }
        $table.EndLoadData()
    } finally { $parser.Close() }

    $vx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1200" Height="720" FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterOwner" Background="#F4F5F7">
  <DockPanel Margin="12">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <Button x:Name="ExternalButton" DockPanel.Dock="Right" Content="Open in default app" Padding="12,5" Margin="8,0,0,0"/>
      <TextBlock x:Name="RowsText" DockPanel.Dock="Right" VerticalAlignment="Center" Foreground="#6B7280" Margin="10,0,0,0"/>
      <TextBlock Text="Filter" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#374151"/>
      <TextBox x:Name="FilterBox" Padding="6,4"/>
    </DockPanel>
    <DataGrid x:Name="Grid" IsReadOnly="True" AutoGenerateColumns="True" CanUserSortColumns="True" HeadersVisibility="Column"
              EnableRowVirtualization="True" EnableColumnVirtualization="True" AlternatingRowBackground="#F9FAFB"
              GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#E5E7EB" Background="White" BorderBrush="#E2E5EA"/>
  </DockPanel>
</Window>
'@
    $vw = [Windows.Markup.XamlReader]::Parse($vx)
    $vw.Owner = $window
    $vw.Title = (Split-Path $path -Leaf) + ' - AdminDeck'
    $grid = $vw.FindName('Grid'); $filter = $vw.FindName('FilterBox'); $rows = $vw.FindName('RowsText')
    $view = $table.DefaultView
    $grid.ItemsSource = $view
    $rows.Text = "$($table.Rows.Count) rows"
    $filter.Tag = @{ View = $view; Table = $table; Rows = $rows }
    $filter.Add_TextChanged({
        $st = $this.Tag
        $q = $this.Text.Trim()
        if (-not $q) { $st.View.RowFilter = ''; $st.Rows.Text = "$($st.Table.Rows.Count) rows"; return }
        $lit = ''
        foreach ($ch in $q.ToCharArray()) {
            if ('[]*%'.Contains([string]$ch)) { $lit += "[$ch]" } elseif ($ch -eq "'") { $lit += "''" } else { $lit += $ch }
        }
        $parts = foreach ($col in $st.Table.Columns) { "[" + $col.ColumnName.Replace(']', '\]') + "] LIKE '%$lit%'" }
        try { $st.View.RowFilter = ($parts -join ' OR ') } catch { }
        $st.Rows.Text = "$($st.View.Count) of $($st.Table.Rows.Count) rows"
    })
    $ext = $vw.FindName('ExternalButton')
    $ext.Tag = $path
    $ext.Add_Click({ Start-Process -FilePath $this.Tag })
    $vw.Show()
}

# ---------------------------------------------------------------- dialogs
function Show-ProfileDialog {
    $px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Connection profile" Width="560" SizeToContent="Height" ResizeMode="NoResize" FontFamily="Segoe UI" FontSize="13"
        WindowStartupLocation="CenterOwner" Background="White">
  <StackPanel Margin="20">
    <TextBlock TextWrapping="Wrap" Foreground="#4B5563" Margin="0,0,0,14"
      Text="Values here pre-fill the matching sign-in fields of every script (TenantId, ClientId, CertificateThumbprint, ...). Use it for certificate-based (unattended) auth with an Entra app registration. Passwords and secrets are never stored."/>
    <Grid x:Name="Fields"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="Clear" Content="Clear all" Padding="12,5" Margin="0,0,8,0"/>
      <Button x:Name="Cancel" Content="Cancel" Padding="12,5" Margin="0,0,8,0" IsCancel="True"/>
      <Button x:Name="Save" Content="Save" Padding="18,5" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dw = [Windows.Markup.XamlReader]::Parse($px)
    $dw.Owner = $window
    $g = $dw.FindName('Fields')
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '170'
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
    $boxes = @{}
    $prof = $script:Settings.Profile
    foreach ($k in $script:ProfileKeys) {
        $r = New-Object Windows.Controls.RowDefinition; $r.Height = 'Auto'; $g.RowDefinitions.Add($r)
        $i = $g.RowDefinitions.Count - 1
        $l = New-Object Windows.Controls.TextBlock; $l.Text = $k; $l.VerticalAlignment = 'Center'; $l.Margin = '0,0,0,8'
        $t = New-Object Windows.Controls.TextBox; $t.Margin = '0,0,0,8'; $t.Padding = '5,4'
        if ($prof.ContainsKey($k)) { $t.Text = [string]$prof[$k] }
        [Windows.Controls.Grid]::SetRow($l, $i); [Windows.Controls.Grid]::SetRow($t, $i); [Windows.Controls.Grid]::SetColumn($t, 1)
        [void]$g.Children.Add($l); [void]$g.Children.Add($t)
        $boxes[$k] = $t
    }
    $dw.FindName('Clear').Tag = $boxes
    $dw.FindName('Clear').Add_Click({ foreach ($b in $this.Tag.Values) { $b.Text = '' } })
    $dw.FindName('Save').Add_Click({ (Get-Window $this).DialogResult = $true })
    if ($dw.ShowDialog()) {
        $new = @{}
        foreach ($k in $boxes.Keys) { if ($boxes[$k].Text.Trim()) { $new[$k] = $boxes[$k].Text.Trim() } }
        $script:Settings.Profile = $new
        Save-AdSettings
        if ($script:Current) { Restore-FormValues }
    }
}

function Get-Window($element) { [Windows.Window]::GetWindow($element) }

function Start-ModuleCheck {
    $script:ModuleStatus = $null
    $ui.ModuleStatusText.Text = 'Checking installed modules...'
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($names)
        $h = @{}
        foreach ($n in $names) {
            $m = Get-Module -ListAvailable -Name $n -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
            $h[$n] = $(if ($m) { [string]$m.Version } else { $null })
        }
        $h
    }).AddArgument((Get-AdKnownModules))
    $script:ModuleJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Complete-ModuleCheck {
    if (-not $script:ModuleJob -or -not $script:ModuleJob.Handle.IsCompleted) { return }
    try {
        $res = $script:ModuleJob.PS.EndInvoke($script:ModuleJob.Handle)
        $script:ModuleStatus = $res[0]
    } catch { $script:ModuleStatus = @{} }
    $script:ModuleJob.PS.Dispose(); $script:ModuleJob = $null
    $have = @($script:ModuleStatus.Values | Where-Object { $_ }).Count
    $ui.ModuleStatusText.Text = "Modules: $have of $($script:ModuleStatus.Count) installed (Windows PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor))"
    if ($script:Current) { Update-Badges }
    if ($script:ModulesWindowList) { Update-ModulesList }
}

function Update-ModulesList {
    $items = foreach ($m in (Get-AdKnownModules)) {
        $users = @($script:Catalog | Where-Object { $_.Modules -contains $m }).Count
        $ver = $null
        if ($script:ModuleStatus) { $ver = $script:ModuleStatus[$m] }
        $note = switch ($m) {
            'MSOnline' { 'retired by Microsoft; legacy scripts only' }
            'AzureAD' { 'retired by Microsoft; legacy scripts only' }
            'PnP.PowerShell' { 'v2+ needs PowerShell 7 and your own Entra app' }
            default { '' }
        }
        [pscustomobject]@{
            Name = $m; Users = $users; Note = $note
            Installed = $(if ($null -eq $script:ModuleStatus) { 'checking...' } elseif ($ver) { $ver } else { 'not installed' })
        }
    }
    $script:ModulesWindowList.ItemsSource = @($items)
}

function Show-ModulesWindow {
    $mx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PowerShell modules" Width="860" Height="420" FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterOwner" Background="White">
  <DockPanel Margin="16">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#4B5563" Margin="0,0,0,10"
      Text="Modules the scripts use, as seen by this PowerShell. Install / Update opens a console running Install-Module -Scope CurrentUser in the shell selected on the Run tab."/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Recheck" Content="Recheck" Padding="12,5" Margin="0,0,8,0"/>
      <Button x:Name="Install" Content="Install / Update selected" Padding="12,5"/>
    </StackPanel>
    <ListView x:Name="List">
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Module" Width="270" DisplayMemberBinding="{Binding Name}"/>
          <GridViewColumn Header="Installed" Width="110" DisplayMemberBinding="{Binding Installed}"/>
          <GridViewColumn Header="Scripts" Width="60" DisplayMemberBinding="{Binding Users}"/>
          <GridViewColumn Header="Note" Width="330" DisplayMemberBinding="{Binding Note}"/>
        </GridView>
      </ListView.View>
    </ListView>
  </DockPanel>
</Window>
'@
    $mw = [Windows.Markup.XamlReader]::Parse($mx)
    $mw.Owner = $window
    $script:ModulesWindowList = $mw.FindName('List')
    Update-ModulesList
    $mw.FindName('Recheck').Add_Click({ Start-ModuleCheck; Update-ModulesList })
    $mw.FindName('Install').Add_Click({
        try {
            $sel = $script:ModulesWindowList.SelectedItem
            if (-not $sel) { return }
            $cmd = "Install-Module -Name '$($sel.Name)' -Scope CurrentUser -Repository PSGallery -AllowClobber -Force; Write-Host 'Done. Close this window and click Recheck.' -ForegroundColor Green"
            Start-Process -FilePath (Get-SelectedShell) -ArgumentList @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
        } catch { Show-AdError $_ }
    })
    $mw.Add_Closed({ $script:ModulesWindowList = $null })
    $mw.Show()
}

# ---------------------------------------------------------------- wiring
$ui.ShellCombo.Items.Add('Windows PowerShell 5.1') | Out-Null
$ui.ShellCombo.Items.Add($(if ($script:PwshPath) { 'PowerShell 7 (pwsh)' } else { 'PowerShell 7 (not installed)' })) | Out-Null
$ui.ShellCombo.SelectedIndex = 0
$ui.KeepOpenCheck.IsChecked = [bool]$script:Settings.KeepOpen
$ui.TranscriptCheck.IsChecked = [bool]$script:Settings.Transcript
$ui.OutRootBox.Text = $script:Settings.OutputRoot

$ui.SearchBox.Add_TextChanged({
    $ui.SearchHint.Visibility = $(if ($ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' })
    Update-ScriptList
})
$ui.AreaFilter.Add_SelectionChanged({ Update-ScriptList })
$ui.CategoryFilter.Add_SelectionChanged({ Update-ScriptList })
$ui.FavOnly.Add_Click({ Update-ScriptList })
$ui.ReadOnlyOnly.Add_Click({ Update-ScriptList })
$ui.ScriptList.Add_SelectionChanged({
    if ($script:Loading) { return }
    $it = $ui.ScriptList.SelectedItem
    if ($it) { try { Show-Script $it.Id } catch { Show-AdError $_ } }
})
$ui.ShellCombo.Add_SelectionChanged({
    if ($ui.ShellCombo.SelectedIndex -eq 1 -and -not $script:PwshPath) {
        $ui.ShellCombo.SelectedIndex = 0
        [void][Windows.MessageBox]::Show('PowerShell 7 is not installed. Get it with: winget install Microsoft.PowerShell', 'AdminDeck')
    }
})
$ui.FavButton.Add_Click({
    $id = $script:Current.Id
    $f = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($script:Settings.Favorites)) { if ($x) { $f.Add($x) } }
    if ($f.Contains($id)) { [void]$f.Remove($id) } else { $f.Add($id) }
    $script:Settings.Favorites = $f.ToArray()
    Save-AdSettings; Update-FavButton; Update-ScriptList
})
$ui.DocsButton.Add_Click({ if ($script:Current.DocsUrl) { Start-Process $script:Current.DocsUrl } })
$ui.ReadmeButton.Add_Click({ Start-Process (Join-Path $script:Current.Folder 'README.md') })
$ui.FolderButton.Add_Click({ Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:Current.Path) })
$ui.EditButton.Add_Click({
    $code = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($code) { Start-Process -FilePath $code.Source -ArgumentList ('"{0}"' -f $script:Current.Path) -WindowStyle Hidden }
    else { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $script:Current.Path) }
})
$ui.CopyButton.Add_Click({
    if (-not $script:Current) { return }
    # Copy the masked display form: secrets stay out of the clipboard.
    [Windows.Clipboard]::SetText($ui.PreviewBox.Text)
    $ui.StatusText.Text = 'Command copied (secrets masked).'
})
$ui.RunButton.Add_Click({ try { Start-AdScript } catch { Show-AdError $_ } })
$ui.ResetButton.Add_Click({
    if (-not $script:Current) { return }
    Build-Form; Restore-FormValues -Defaults
})
$ui.OutBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $ui.OutRootBox.Text
    if ($dlg.ShowDialog() -eq 'OK') { $ui.OutRootBox.Text = $dlg.SelectedPath }
})
$ui.OutRootBox.Add_LostFocus({ $script:OutputSignature = ''; Update-Outputs })
$ui.Tabs.Add_SelectionChanged({
    if ($_.OriginalSource -ne $ui.Tabs) { return }
    if ($ui.Tabs.SelectedItem -eq $ui.SourceTab) { Show-Source }
    if ($ui.Tabs.SelectedItem -eq $ui.OutputsTab) { Update-Outputs }
})
$ui.OutViewButton.Add_Click({
    $it = Get-SelectedOutput
    if (-not $it) { return }
    if ($it.Name -notmatch '\.csv$') { Start-Process $it.FullName; return }
    try { Show-CsvViewer $it.FullName } catch { Show-AdError $_ }
})
$ui.OutputList.Add_MouseDoubleClick({
    $it = $ui.OutputList.SelectedItem
    if (-not $it) { return }
    if ($it.Name -match '\.csv$') { try { Show-CsvViewer $it.FullName } catch { Show-AdError $_ } } else { Start-Process $it.FullName }
})
$ui.OutOpenButton.Add_Click({ $it = Get-SelectedOutput; if ($it) { Start-Process $it.FullName } })
$ui.OutShowButton.Add_Click({ $it = Get-SelectedOutput; if ($it) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $it.FullName) } })
$ui.OutFolderButton.Add_Click({
    $d = Get-OutputDir
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $d)
})
$ui.ProfileButton.Add_Click({ try { Show-ProfileDialog } catch { Show-AdError $_ } })
$ui.ModulesButton.Add_Click({ try { Show-ModulesWindow } catch { Show-AdError $_ } })
$ui.ReportsButton.Add_Click({
    $d = $ui.OutRootBox.Text.Trim()
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $d)
})
$ui.UnblockButton.Add_Click({
    try {
        $all = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Include *.ps1, *.psm1)
        $blocked = @($all | Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
        $blocked | Unblock-File
        [void][Windows.MessageBox]::Show("Removed the downloaded-from-internet mark from $($blocked.Count) of $($all.Count) script files.", 'AdminDeck')
    } catch { Show-AdError $_ }
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    try {
        Complete-ModuleCheck
        if ($script:Current -and $window.IsActive) { Update-Outputs }
    } catch { Write-AdError $_ }
})

$window.Add_Closing({
    $script:Settings.OutputRoot = $ui.OutRootBox.Text.Trim()
    $script:Settings.KeepOpen = [bool]$ui.KeepOpenCheck.IsChecked
    $script:Settings.Transcript = [bool]$ui.TranscriptCheck.IsChecked
    Save-AdSettings
    $timer.Stop()
})

Update-ScriptList
Start-ModuleCheck
$timer.Start()

# ---------------------------------------------------------------- render mode (testing)
if ($RenderTo) {
    if ($RenderSearch) { $ui.SearchBox.Text = $RenderSearch }
    if ($RenderSelect) {
        $hit = @($ui.ScriptList.ItemsSource | Where-Object { $_.Name -like $RenderSelect }) | Select-Object -First 1
        if ($hit) { $ui.ScriptList.SelectedItem = $hit }
    }
    $ui.Tabs.SelectedIndex = @{ Run = 0; Outputs = 1; Source = 2 }[$RenderTab]
    $deadline = (Get-Date).AddSeconds(15)
    while ($script:ModuleJob -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    Complete-ModuleCheck
    function Save-AdRender($w, $element, [string]$path) {
        $w.WindowStartupLocation = 'Manual'; $w.Left = -30000; $w.Top = -30000; $w.ShowActivated = $false; $w.ShowInTaskbar = $false
        if (-not $w.IsVisible) { $w.Show() }
        $w.UpdateLayout()
        $w.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$element.ActualWidth), ([int]$element.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($element)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($path)
        try { $enc.Save($fs) } finally { $fs.Close() }
        Write-Host "Rendered $path"
    }
    $window.WindowStartupLocation = 'Manual'; $window.Left = -30000; $window.Top = -30000
    Save-AdRender $window $ui.Root $RenderTo
    if ($RenderTab -eq 'Outputs' -and $ui.OutputList.Items.Count) {
        # Also render the grid viewer for the newest CSV, filtered by the search text.
        $csv = @($ui.OutputList.ItemsSource | Where-Object { $_.Name -match '\.csv$' }) | Select-Object -First 1
        if ($csv) {
            Show-CsvViewer $csv.FullName
            $vw = @($window.OwnedWindows)[-1]
            if ($RenderSearch) { $vw.FindName('FilterBox').Text = 'contoso' }
            Save-AdRender $vw $vw.Content ($RenderTo -replace '\.png$', '-csv.png')
        }
    }
    $timer.Stop()
    $window.Close()
    return
}

try {
    [void]$window.ShowDialog()
} catch {
    Show-AdError $_
}
