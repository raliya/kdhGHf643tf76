& {
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

    $ProjectRoot = 'C:\Users\User\Desktop\Adminki\. Программа домены\Новая папка'
    $ProjectFile = Join-Path $ProjectRoot 'TextFileProcessor.csproj'
    $MainWindowXaml = Join-Path $ProjectRoot 'MainWindow.xaml'
    $MainWindowCode = Join-Path $ProjectRoot 'MainWindow.xaml.cs'
    $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $BackupDirectory = Join-Path $ProjectRoot "backup-before-build6-$Timestamp"
    $PublishDirectory = Join-Path $ProjectRoot 'publish-build6'
    $BuildLog = Join-Path $ProjectRoot 'build6.log'
    $PublishLog = Join-Path $ProjectRoot 'publish-build6.log'
    $ReportPath = Join-Path $ProjectRoot 'BUILD6-CHANGES.txt'
    $Utf8Bom = [System.Text.UTF8Encoding]::new($true)

    function Write-Utf8File {
        param(
            [Parameter(Mandatory)]
            [string]$Path,

            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$Content
        )

        $parent = Split-Path $Path -Parent

        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        [System.IO.File]::WriteAllText(
            $Path,
            ($Content -replace "`r?`n", "`r`n"),
            $Utf8Bom
        )
    }

    function Backup-ProjectFile {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return
        }

        $relative = $Path.Substring($ProjectRoot.Length).TrimStart('\')
        $destination = Join-Path $BackupDirectory $relative
        $destinationDirectory = Split-Path $destination -Parent

        New-Item -ItemType Directory `
            -Path $destinationDirectory `
            -Force | Out-Null

        Copy-Item -LiteralPath $Path -Destination $destination -Force
    }

    Write-Host '=== УСТАНОВКА СБОРКИ 6 ===' -ForegroundColor Cyan

    foreach ($requiredFile in @(
        $ProjectFile,
        $MainWindowXaml,
        $MainWindowCode
    )) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Не найден обязательный файл: $requiredFile"
        }
    }

    $xamlText = [System.IO.File]::ReadAllText($MainWindowXaml)

    $classMatch = [regex]::Match(
        $xamlText,
        'x:Class\s*=\s*"([^"]+)"'
    )

    if (-not $classMatch.Success) {
        throw 'Не удалось определить x:Class из MainWindow.xaml.'
    }

    $fullClassName = $classMatch.Groups[1].Value
    $lastDot = $fullClassName.LastIndexOf('.')

    if ($lastDot -lt 1) {
        throw "Некорректный x:Class: $fullClassName"
    }

    $Namespace = $fullClassName.Substring(0, $lastDot)
    $MainWindowClass = $fullClassName.Substring($lastDot + 1)

    Write-Host "Namespace: $Namespace"
    Write-Host "Главное окно: $MainWindowClass"

    New-Item -ItemType Directory `
        -Path $BackupDirectory `
        -Force | Out-Null

    $Build6MainWindow = Join-Path $ProjectRoot 'MainWindow.Build6.cs'
    $Build6Window = Join-Path $ProjectRoot 'Build6VerificationWindow.cs'
    $ResultFile = Join-Path $ProjectRoot `
        'Models\WebsiteVerificationResult.cs'
    $ServiceFile = Join-Path $ProjectRoot `
        'Services\WebsiteVerificationService.cs'

    foreach ($file in @(
        $MainWindowCode,
        $Build6MainWindow,
        $Build6Window,
        $ResultFile,
        $ServiceFile,
        $ReportPath
    )) {
        Backup-ProjectFile $file
    }

    $resultCode = @'
using System;
using System.Collections.Generic;

namespace __NAMESPACE__.Models
{
    public sealed class WebsiteVerificationResult
    {
        public string Domain { get; set; } = string.Empty;

        public bool DnsResolved { get; set; }

        public List<string> IpAddresses { get; set; } = new();

        public bool HttpAvailable { get; set; }

        public int? HttpStatusCode { get; set; }

        public string HttpFinalUrl { get; set; } = string.Empty;

        public bool HttpsAvailable { get; set; }

        public int? HttpsStatusCode { get; set; }

        public string HttpsFinalUrl { get; set; } = string.Empty;

        public bool CertificatePresent { get; set; }

        public bool CertificateValid { get; set; }

        public string CertificateSubject { get; set; } = string.Empty;

        public string CertificateIssuer { get; set; } = string.Empty;

        public DateTimeOffset? CertificateExpiresAt { get; set; }

        public string CertificateError { get; set; } = string.Empty;

        public string ControlText { get; set; } = string.Empty;

        public bool ControlTextRequired { get; set; }

        public bool ControlTextFound { get; set; }

        public TimeSpan Duration { get; set; }

        public List<string> Errors { get; set; } = new();

        public bool Success =>
            DnsResolved &&
            HttpsAvailable &&
            CertificatePresent &&
            CertificateValid &&
            (!ControlTextRequired || ControlTextFound);
    }
}
'@.Replace('__NAMESPACE__', $Namespace)

    $serviceCode = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using __NAMESPACE__.Models;

namespace __NAMESPACE__.Services
{
    public sealed class WebsiteVerificationService
    {
        private const int MaximumBodyCharacters = 2_000_000;

        public async Task<WebsiteVerificationResult> VerifyAsync(
            string domainOrUrl,
            string? controlText,
            TimeSpan timeout,
            CancellationToken cancellationToken = default)
        {
            var result = new WebsiteVerificationResult();
            var stopwatch = Stopwatch.StartNew();

            try
            {
                string host = GetSafeHost(domainOrUrl);

                result.Domain = host;
                result.ControlText = controlText?.Trim() ?? string.Empty;
                result.ControlTextRequired =
                    !string.IsNullOrWhiteSpace(result.ControlText);

                await VerifyDnsAsync(
                    host,
                    result,
                    cancellationToken);

                if (!result.DnsResolved)
                {
                    return result;
                }

                string httpBody = await VerifyHttpAsync(
                    new Uri($"http://{host}/"),
                    false,
                    result,
                    timeout,
                    cancellationToken);

                string httpsBody = await VerifyHttpAsync(
                    new Uri($"https://{host}/"),
                    true,
                    result,
                    timeout,
                    cancellationToken);

                if (result.ControlTextRequired)
                {
                    string body = !string.IsNullOrEmpty(httpsBody)
                        ? httpsBody
                        : httpBody;

                    result.ControlTextFound = body.IndexOf(
                        result.ControlText,
                        StringComparison.OrdinalIgnoreCase) >= 0;
                }
                else
                {
                    result.ControlTextFound = true;
                }
            }
            catch (OperationCanceledException)
            {
                result.Errors.Add("Проверка отменена или превышен тайм-аут.");
            }
            catch (Exception ex)
            {
                result.Errors.Add(GetSafeError(ex));
            }
            finally
            {
                stopwatch.Stop();
                result.Duration = stopwatch.Elapsed;
            }

            return result;
        }

        private static string GetSafeHost(string value)
        {
            value = value?.Trim() ?? string.Empty;

            if (string.IsNullOrWhiteSpace(value))
            {
                throw new ArgumentException("Не указан домен.");
            }

            Uri uri;

            if (!Uri.TryCreate(value, UriKind.Absolute, out uri!))
            {
                if (!Uri.TryCreate(
                    "https://" + value,
                    UriKind.Absolute,
                    out uri!))
                {
                    throw new ArgumentException("Некорректный домен или URL.");
                }
            }

            if (uri.Scheme != Uri.UriSchemeHttp &&
                uri.Scheme != Uri.UriSchemeHttps)
            {
                throw new ArgumentException(
                    "Разрешены только HTTP- и HTTPS-адреса.");
            }

            if (!string.IsNullOrEmpty(uri.UserInfo))
            {
                throw new ArgumentException(
                    "URL не должен содержать имя пользователя или пароль.");
            }

            if (string.IsNullOrWhiteSpace(uri.Host))
            {
                throw new ArgumentException("Не удалось определить домен.");
            }

            if (uri.IsLoopback)
            {
                throw new ArgumentException(
                    "Локальные адреса для этой проверки не поддерживаются.");
            }

            return new System.Globalization.IdnMapping().GetAscii(uri.Host);
        }

        private static async Task VerifyDnsAsync(
            string host,
            WebsiteVerificationResult result,
            CancellationToken cancellationToken)
        {
            try
            {
                IPAddress[] addresses = await Dns.GetHostAddressesAsync(
                    host,
                    cancellationToken);

                result.IpAddresses = addresses
                    .Select(address => address.ToString())
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToList();

                result.DnsResolved = result.IpAddresses.Count > 0;

                if (!result.DnsResolved)
                {
                    result.Errors.Add(
                        "DNS не вернул IP-адреса домена.");
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                result.DnsResolved = false;
                result.Errors.Add("Ошибка DNS: " + GetSafeError(ex));
            }
        }

        private static async Task<string> VerifyHttpAsync(
            Uri address,
            bool isHttps,
            WebsiteVerificationResult result,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            X509Certificate2? serverCertificate = null;
            SslPolicyErrors certificateErrors = SslPolicyErrors.None;

            using var handler = new HttpClientHandler
            {
                AllowAutoRedirect = true,
                MaxAutomaticRedirections = 10,
                AutomaticDecompression =
                    DecompressionMethods.GZip |
                    DecompressionMethods.Deflate |
                    DecompressionMethods.Brotli
            };

            if (isHttps)
            {
                handler.ServerCertificateCustomValidationCallback =
                    (_, certificate, _, errors) =>
                    {
                        certificateErrors = errors;

                        if (certificate != null)
                        {
                            serverCertificate =
                                new X509Certificate2(certificate);
                        }

                        // Проверка сертификата не отключается.
                        return errors == SslPolicyErrors.None;
                    };
            }

            using var client = new HttpClient(handler)
            {
                Timeout = timeout
            };

            client.DefaultRequestHeaders.UserAgent.ParseAdd(
                "TextFileProcessor-Build6/1.0");

            try
            {
                using var request = new HttpRequestMessage(
                    HttpMethod.Get,
                    address);

                using HttpResponseMessage response =
                    await client.SendAsync(
                        request,
                        HttpCompletionOption.ResponseHeadersRead,
                        cancellationToken);

                int statusCode = (int)response.StatusCode;
                string finalUrl =
                    response.RequestMessage?.RequestUri?.ToString() ??
                    address.ToString();

                if (isHttps)
                {
                    result.HttpsAvailable = true;
                    result.HttpsStatusCode = statusCode;
                    result.HttpsFinalUrl = finalUrl;
                    result.CertificatePresent =
                        serverCertificate != null;
                    result.CertificateValid =
                        serverCertificate != null &&
                        certificateErrors == SslPolicyErrors.None;

                    if (serverCertificate != null)
                    {
                        result.CertificateSubject =
                            serverCertificate.Subject;
                        result.CertificateIssuer =
                            serverCertificate.Issuer;
                        result.CertificateExpiresAt =
                            new DateTimeOffset(
                                serverCertificate.NotAfter);
                    }

                    if (certificateErrors != SslPolicyErrors.None)
                    {
                        result.CertificateError =
                            certificateErrors.ToString();
                    }
                }
                else
                {
                    result.HttpAvailable = true;
                    result.HttpStatusCode = statusCode;
                    result.HttpFinalUrl = finalUrl;
                }

                return await ReadLimitedBodyAsync(
                    response,
                    cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                if (isHttps)
                {
                    result.HttpsAvailable = false;
                    result.CertificatePresent =
                        serverCertificate != null;
                    result.CertificateValid = false;

                    if (serverCertificate != null)
                    {
                        result.CertificateSubject =
                            serverCertificate.Subject;
                        result.CertificateIssuer =
                            serverCertificate.Issuer;
                        result.CertificateExpiresAt =
                            new DateTimeOffset(
                                serverCertificate.NotAfter);
                    }

                    if (certificateErrors != SslPolicyErrors.None)
                    {
                        result.CertificateError =
                            certificateErrors.ToString();
                    }

                    result.Errors.Add(
                        "Ошибка HTTPS: " + GetSafeError(ex));
                }
                else
                {
                    result.HttpAvailable = false;
                    result.Errors.Add(
                        "Ошибка HTTP: " + GetSafeError(ex));
                }

                return string.Empty;
            }
            finally
            {
                serverCertificate?.Dispose();
            }
        }

        private static async Task<string> ReadLimitedBodyAsync(
            HttpResponseMessage response,
            CancellationToken cancellationToken)
        {
            await using Stream stream =
                await response.Content.ReadAsStreamAsync(
                    cancellationToken);

            using var reader = new StreamReader(
                stream,
                Encoding.UTF8,
                true,
                8192,
                leaveOpen: false);

            var builder = new StringBuilder();
            var buffer = new char[8192];

            while (builder.Length < MaximumBodyCharacters)
            {
                int requested = Math.Min(
                    buffer.Length,
                    MaximumBodyCharacters - builder.Length);

                int read = await reader.ReadAsync(
                    buffer.AsMemory(0, requested),
                    cancellationToken);

                if (read <= 0)
                {
                    break;
                }

                builder.Append(buffer, 0, read);
            }

            return builder.ToString();
        }

        private static string GetSafeError(Exception exception)
        {
            string message = exception.Message
                .Replace("\r", " ")
                .Replace("\n", " ")
                .Trim();

            return message.Length <= 500
                ? message
                : message.Substring(0, 500);
        }
    }
}
'@.Replace('__NAMESPACE__', $Namespace)

    $windowCode = @'
using System;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using __NAMESPACE__.Models;
using __NAMESPACE__.Services;

namespace __NAMESPACE__
{
    public sealed class Build6VerificationWindow : Window
    {
        private readonly TextBox _domainTextBox;
        private readonly TextBox _controlTextBox;
        private readonly TextBox _timeoutTextBox;
        private readonly Button _verifyButton;
        private readonly Button _cancelButton;
        private readonly TextBox _resultTextBox;
        private readonly ProgressBar _progressBar;

        private CancellationTokenSource? _cancellationTokenSource;

        public Build6VerificationWindow()
        {
            Title = "Сборка 6 — проверка опубликованного сайта";
            Width = 820;
            Height = 720;
            MinWidth = 650;
            MinHeight = 520;
            WindowStartupLocation =
                WindowStartupLocation.CenterOwner;

            var root = new Grid
            {
                Margin = new Thickness(16)
            };

            root.RowDefinitions.Add(
                new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(
                new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(
                new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(
                new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(
                new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(
                new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

            var title = new TextBlock
            {
                Text = "Финальная проверка сайта",
                FontSize = 22,
                FontWeight = FontWeights.Bold,
                Margin = new Thickness(0, 0, 0, 16)
            };

            Grid.SetRow(title, 0);
            root.Children.Add(title);

            _domainTextBox = AddInput(
                root,
                1,
                "Домен или URL:",
                "example.com");

            _controlTextBox = AddInput(
                root,
                2,
                "Контрольный текст (необязательно):",
                string.Empty);

            _timeoutTextBox = AddInput(
                root,
                3,
                "Тайм-аут в секундах:",
                "30");

            var commandPanel = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Margin = new Thickness(0, 12, 0, 12)
            };

            _verifyButton = new Button
            {
                Content = "Проверить сайт",
                MinWidth = 150,
                Height = 36,
                Margin = new Thickness(0, 0, 8, 0)
            };

            _cancelButton = new Button
            {
                Content = "Отмена",
                MinWidth = 100,
                Height = 36,
                IsEnabled = false
            };

            _progressBar = new ProgressBar
            {
                Width = 180,
                Height = 18,
                Margin = new Thickness(16, 9, 0, 0),
                IsIndeterminate = false
            };

            _verifyButton.Click += async (_, _) =>
                await VerifyAsync();

            _cancelButton.Click += (_, _) =>
                _cancellationTokenSource?.Cancel();

            commandPanel.Children.Add(_verifyButton);
            commandPanel.Children.Add(_cancelButton);
            commandPanel.Children.Add(_progressBar);

            Grid.SetRow(commandPanel, 4);
            root.Children.Add(commandPanel);

            _resultTextBox = new TextBox
            {
                IsReadOnly = true,
                AcceptsReturn = true,
                AcceptsTab = true,
                VerticalScrollBarVisibility =
                    ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility =
                    ScrollBarVisibility.Auto,
                TextWrapping = TextWrapping.NoWrap,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 13
            };

            Grid.SetRow(_resultTextBox, 5);
            root.Children.Add(_resultTextBox);

            Content = root;
        }

        private static TextBox AddInput(
            Grid root,
            int row,
            string label,
            string defaultValue)
        {
            var panel = new Grid
            {
                Margin = new Thickness(0, 0, 0, 8)
            };

            panel.ColumnDefinitions.Add(
                new ColumnDefinition { Width = new GridLength(230) });
            panel.ColumnDefinitions.Add(
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var textBlock = new TextBlock
            {
                Text = label,
                VerticalAlignment = VerticalAlignment.Center
            };

            var textBox = new TextBox
            {
                Text = defaultValue,
                MinHeight = 30,
                VerticalContentAlignment =
                    VerticalAlignment.Center
            };

            Grid.SetColumn(textBlock, 0);
            Grid.SetColumn(textBox, 1);

            panel.Children.Add(textBlock);
            panel.Children.Add(textBox);

            Grid.SetRow(panel, row);
            root.Children.Add(panel);

            return textBox;
        }

        private async Task VerifyAsync()
        {
            if (!int.TryParse(
                    _timeoutTextBox.Text,
                    out int timeoutSeconds) ||
                timeoutSeconds < 5 ||
                timeoutSeconds > 300)
            {
                MessageBox.Show(
                    this,
                    "Тайм-аут должен быть от 5 до 300 секунд.",
                    "Сборка 6",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);

                return;
            }

            _cancellationTokenSource?.Dispose();
            _cancellationTokenSource =
                new CancellationTokenSource();

            _verifyButton.IsEnabled = false;
            _cancelButton.IsEnabled = true;
            _progressBar.IsIndeterminate = true;
            _resultTextBox.Text = "Выполняется проверка...";

            try
            {
                var service =
                    new WebsiteVerificationService();

                WebsiteVerificationResult result =
                    await service.VerifyAsync(
                        _domainTextBox.Text,
                        _controlTextBox.Text,
                        TimeSpan.FromSeconds(timeoutSeconds),
                        _cancellationTokenSource.Token);

                _resultTextBox.Text = FormatResult(result);
            }
            catch (Exception ex)
            {
                _resultTextBox.Text =
                    "Непредвиденная ошибка: " + ex.Message;
            }
            finally
            {
                _progressBar.IsIndeterminate = false;
                _verifyButton.IsEnabled = true;
                _cancelButton.IsEnabled = false;
            }
        }

        private static string FormatResult(
            WebsiteVerificationResult result)
        {
            var text = new StringBuilder();

            text.AppendLine("РЕЗУЛЬТАТ ПРОВЕРКИ");
            text.AppendLine(
                "========================================");
            text.AppendLine($"Домен: {result.Domain}");
            text.AppendLine(
                $"Общий результат: {(result.Success ? "УСПЕШНО" : "ЕСТЬ ПРОБЛЕМЫ")}");
            text.AppendLine(
                $"Время: {result.Duration.TotalSeconds:F2} сек.");
            text.AppendLine();

            text.AppendLine(
                $"DNS: {(result.DnsResolved ? "успешно" : "ошибка")}");

            text.AppendLine(
                "IP: " +
                (result.IpAddresses.Count > 0
                    ? string.Join(", ", result.IpAddresses)
                    : "не найдены"));

            text.AppendLine();
            text.AppendLine(
                $"HTTP: {(result.HttpAvailable ? "доступен" : "недоступен")}");
            text.AppendLine(
                $"HTTP-код: {result.HttpStatusCode?.ToString() ?? "нет"}");
            text.AppendLine(
                $"Конечный HTTP URL: {result.HttpFinalUrl}");

            text.AppendLine();
            text.AppendLine(
                $"HTTPS: {(result.HttpsAvailable ? "доступен" : "недоступен")}");
            text.AppendLine(
                $"HTTPS-код: {result.HttpsStatusCode?.ToString() ?? "нет"}");
            text.AppendLine(
                $"Конечный HTTPS URL: {result.HttpsFinalUrl}");

            text.AppendLine();
            text.AppendLine(
                $"TLS-сертификат: {(result.CertificatePresent ? "получен" : "не получен")}");
            text.AppendLine(
                $"TLS действителен: {(result.CertificateValid ? "да" : "нет")}");
            text.AppendLine(
                $"Владелец: {result.CertificateSubject}");
            text.AppendLine(
                $"Издатель: {result.CertificateIssuer}");
            text.AppendLine(
                $"Действует до: {result.CertificateExpiresAt?.ToString("yyyy-MM-dd HH:mm:ss zzz") ?? "не определено"}");

            if (!string.IsNullOrWhiteSpace(
                    result.CertificateError))
            {
                text.AppendLine(
                    $"Ошибка TLS: {result.CertificateError}");
            }

            text.AppendLine();

            if (result.ControlTextRequired)
            {
                text.AppendLine(
                    $"Контрольный текст: {(result.ControlTextFound ? "найден" : "не найден")}");
            }
            else
            {
                text.AppendLine(
                    "Контрольный текст: проверка не требовалась");
            }

            if (result.Errors.Count > 0)
            {
                text.AppendLine();
                text.AppendLine("ОШИБКИ И ПРЕДУПРЕЖДЕНИЯ:");

                foreach (string error in result.Errors)
                {
                    text.AppendLine("- " + error);
                }
            }

            return text.ToString();
        }
    }
}
'@.Replace('__NAMESPACE__', $Namespace)

    $mainWindowBuild6Code = @'
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace __NAMESPACE__
{
    public partial class __MAIN_WINDOW_CLASS__
    {
        private void InitializeBuild6()
        {
            if (FindName("Build6WebsiteVerificationButton") != null)
            {
                return;
            }

            UIElement? previousContent = Content as UIElement;

            if (previousContent == null)
            {
                return;
            }

            Content = null;

            var host = new Grid();
            host.Children.Add(previousContent);

            var button = new Button
            {
                Name = "Build6WebsiteVerificationButton",
                Content = "Сборка 6: проверить сайт",
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(12),
                Padding = new Thickness(14, 8, 14, 8),
                Background = new SolidColorBrush(
                    Color.FromRgb(34, 120, 190)),
                Foreground = Brushes.White,
                FontWeight = FontWeights.SemiBold,
                ToolTip = "DNS, HTTP, HTTPS, TLS и контрольный текст"
            };

            button.Click += (_, _) =>
            {
                var verificationWindow =
                    new Build6VerificationWindow
                    {
                        Owner = this
                    };

                verificationWindow.ShowDialog();
            };

            host.Children.Add(button);
            Content = host;
        }
    }
}
'@.Replace('__NAMESPACE__', $Namespace).
    Replace('__MAIN_WINDOW_CLASS__', $MainWindowClass)

    Write-Utf8File $ResultFile $resultCode
    Write-Utf8File $ServiceFile $serviceCode
    Write-Utf8File $Build6Window $windowCode
    Write-Utf8File $Build6MainWindow $mainWindowBuild6Code

    $mainCodeText = [System.IO.File]::ReadAllText(
        $MainWindowCode
    )

    if ($mainCodeText -notmatch '\bInitializeBuild6\s*[(]\s*[)]\s*;') {
        $initializeMatches = [regex]::Matches(
            $mainCodeText,
            '\bInitializeComponent\s*[(]\s*[)]\s*;'
        )

        if ($initializeMatches.Count -eq 0) {
            throw @"
В MainWindow.xaml.cs не найден вызов InitializeComponent().
Исходный файл сохранён без изменения. Резервная копия:
$BackupDirectory
"@
        }

        $firstMatch = $initializeMatches[0]
        $insertionPosition =
            $firstMatch.Index + $firstMatch.Length

        $mainCodeText = $mainCodeText.Insert(
            $insertionPosition,
            "`r`n            InitializeBuild6();"
        )

        Write-Utf8File $MainWindowCode $mainCodeText

        Write-Host `
            'В MainWindow.xaml.cs добавлен InitializeBuild6().' `
            -ForegroundColor Green
    }
    else {
        Write-Host `
            'InitializeBuild6() уже подключён.' `
            -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Компиляция Release...' -ForegroundColor Cyan

    $buildOutput = & dotnet build `
        $ProjectFile `
        -c Release `
        --nologo 2>&1

    $buildExitCode = $LASTEXITCODE
    $buildText = $buildOutput | Out-String

    Write-Utf8File $BuildLog $buildText
    $buildOutput | ForEach-Object { Write-Host $_ }

    if ($buildExitCode -ne 0) {
        Write-Host ''
        Write-Host 'СБОРКА 6 НЕ СКОМПИЛИРОВАЛАСЬ.' `
            -ForegroundColor Red
        Write-Host "Журнал: $BuildLog"
        Write-Host "Резервная копия: $BackupDirectory"
        throw "dotnet build завершился с кодом $buildExitCode"
    }

    Write-Host ''
    Write-Host 'Публикация Сборки 6...' -ForegroundColor Cyan

    if (Test-Path -LiteralPath $PublishDirectory) {
        Remove-Item `
            -LiteralPath $PublishDirectory `
            -Recurse `
            -Force
    }

    $publishOutput = & dotnet publish `
        $ProjectFile `
        -c Release `
        -r win-x64 `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $PublishDirectory `
        --nologo 2>&1

    $publishExitCode = $LASTEXITCODE
    $publishText = $publishOutput | Out-String

    Write-Utf8File $PublishLog $publishText
    $publishOutput | ForEach-Object { Write-Host $_ }

    if ($publishExitCode -ne 0) {
        throw "dotnet publish завершился с кодом $publishExitCode"
    }

    $ExePath = Join-Path `
        $PublishDirectory `
        'TextFileProcessor.exe'

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        $foundExe = Get-ChildItem `
            -LiteralPath $PublishDirectory `
            -Filter '*.exe' `
            -File |
            Select-Object -First 1

        if ($null -eq $foundExe) {
            throw 'После публикации не найден EXE-файл.'
        }

        $ExePath = $foundExe.FullName
    }

    $ExeInfo = Get-Item -LiteralPath $ExePath
    $ExeHash = (
        Get-FileHash `
            -LiteralPath $ExePath `
            -Algorithm SHA256
    ).Hash

    $report = @"
ОТЧЁТ О ЗАВЕРШЕНИИ СБОРКИ 6
========================================

Дата: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Проект: $ProjectRoot
Резервная копия: $BackupDirectory

1. НАЗНАЧЕНИЕ
----------------------------------------

Сборка 6 добавляет финальную проверку опубликованного сайта.

2. РЕАЛИЗОВАНО
----------------------------------------

- DNS-разрешение домена.
- Получение списка IP-адресов.
- Проверка HTTP.
- Проверка HTTPS.
- Обработка до 10 перенаправлений.
- Получение конечного URL.
- Получение HTTP-кода.
- Стандартная проверка TLS-сертификата.
- Получение владельца и издателя сертификата.
- Получение срока действия сертификата.
- Поиск необязательного контрольного текста.
- Тайм-аут от 5 до 300 секунд.
- Отмена выполняющейся проверки.
- Ограничение считываемого содержимого страницы.
- Отдельное окно результатов.
- Кнопка запуска проверки в главном окне.

3. СОЗДАННЫЕ ФАЙЛЫ
----------------------------------------

- MainWindow.Build6.cs
- Build6VerificationWindow.cs
- Models\WebsiteVerificationResult.cs
- Services\WebsiteVerificationService.cs
- build6.log
- publish-build6.log
- BUILD6-CHANGES.txt

4. ИЗМЕНЁННЫЕ ФАЙЛЫ
----------------------------------------

MainWindow.xaml.cs:
после InitializeComponent() добавлен вызов InitializeBuild6().

5. РЕЗУЛЬТАТ КОМПИЛЯЦИИ
----------------------------------------

dotnet build: успешно.
dotnet publish: успешно.

EXE:
$ExePath

Размер:
$($ExeInfo.Length) байт

Дата изменения:
$($ExeInfo.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))

SHA256:
$ExeHash

6. ОГРАНИЧЕНИЯ
----------------------------------------

- Результат пока не записывается в SQLite, поскольку структура
  таблиц заданий текущего проекта автоматически не изменялась.
- Проверяется главная страница домена.
- Проверка сертификата не отключается.
- publish-build5 не изменялся.

7. ПРОВЕРКА
----------------------------------------

1. Запустить EXE из publish-build6.
2. Нажать «Сборка 6: проверить сайт».
3. Ввести домен.
4. При необходимости указать контрольный текст.
5. Нажать «Проверить сайт».
6. Проверить DNS, HTTP, HTTPS и TLS в результатах.

8. ИТОГ
----------------------------------------

Сборка 6 скомпилирована и опубликована.

Конец отчёта.
"@

    if ($report.Length -gt 95000) {
        throw 'BUILD6-CHANGES.txt превышает 95000 символов.'
    }

    Write-Utf8File $ReportPath $report

    Write-Host ''
    Write-Host '========================================' `
        -ForegroundColor Green
    Write-Host 'СБОРКА 6 УСПЕШНО СОЗДАНА' `
        -ForegroundColor Green
    Write-Host '========================================' `
        -ForegroundColor Green
    Write-Host "EXE: $ExePath" -ForegroundColor Cyan
    Write-Host "SHA256: $ExeHash"
    Write-Host "Отчёт: $ReportPath"
    Write-Host "Резервная копия: $BackupDirectory"
    Write-Host ''

    Start-Process explorer.exe `
        -ArgumentList "`"$PublishDirectory`""
}
