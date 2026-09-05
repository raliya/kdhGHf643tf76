using System.Windows;
using TextFileProcessor.Models;
using TextFileProcessor.Services;

namespace TextFileProcessor;

public partial class MainWindow
{
    private readonly DatabaseDeploymentService
        _databaseDeploymentService = new();

    private void Build4_Loaded(
        object sender,
        RoutedEventArgs e)
    {
        Build3_Loaded(sender, e);

        Build4StatusTextBlock.Text =
            "Выберите готовое задание, затем создайте БД " +
            "и импортируйте SQL.";
    }

    private async void DeployDatabaseButton_Click(
        object sender,
        RoutedEventArgs e)
    {
        if (_isRunning)
        {
            return;
        }

        var selectedJob =
            JobsGrid.SelectedItem as DomainJob;

        if (selectedJob is null)
        {
            MessageBox.Show(
                this,
                "Сначала выберите домен в таблице «Задания».",
                "Сборка 4 — база данных",
                MessageBoxButton.OK,
                MessageBoxImage.Information);

            return;
        }

        if (string.IsNullOrWhiteSpace(
                selectedJob.OutputPath) ||
            !Directory.Exists(selectedJob.OutputPath))
        {
            MessageBox.Show(
                this,
                "У выбранного задания отсутствует готовая " +
                "локальная папка.",
                "Сборка 4 — база данных",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);

            return;
        }

        var configPath = Path.Combine(
            selectedJob.OutputPath,
            "config",
            "config.php");

        if (!File.Exists(configPath))
        {
            MessageBox.Show(
                this,
                "Не найден обработанный файл:\n" +
                configPath,
                "Сборка 4 — база данных",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);

            return;
        }

        var sqlFiles = Directory
            .EnumerateFiles(
                selectedJob.OutputPath,
                "*.sql",
                SearchOption.AllDirectories)
            .ToList();

        if (sqlFiles.Count == 0)
        {
            MessageBox.Show(
                this,
                "В папке результата не найден SQL-файл.",
                "Сборка 4 — база данных",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);

            return;
        }

        var confirmation = MessageBox.Show(
            this,
            $"Выполнить этап 4 для {selectedJob.Domain}?\n\n" +
            "Программа:\n" +
            "1. Прочитает name, user и pass из config.php.\n" +
            "2. Проверит существование и доступность БД.\n" +
            "3. При необходимости создаст новую БД.\n" +
            "4. Импортирует локальный SQL-файл.\n\n" +
            "Если БД уже существует и реквизиты подходят, " +
            "создание будет пропущено, но SQL будет импортирован.",
            "Подтверждение этапа 4",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (confirmation != MessageBoxResult.Yes)
        {
            return;
        }

        string sshPassword = string.Empty;

        try
        {
            SetBuild3Busy(true);
            DeployDatabaseButton.IsEnabled = false;

            Build4ProgressBar.Value = 0;
            Build4StatusTextBlock.Text =
                "Подготовка этапа 4...";

            var settings = ReadSshSettings();

            sshPassword =
                _sshDeploymentSettingsService.GetPassword(
                    settings,
                    SshPasswordBox.Password);

            settings.Validate(sshPassword);

            var progress =
                new Progress<DatabaseDeploymentProgress>(
                    item =>
                    {
                        Build4ProgressBar.Value =
                            item.Percent;

                        Build4StatusTextBlock.Text =
                            $"{item.Percent}% — {item.Message}";

                        SetStatus(
                            $"{selectedJob.Domain}: " +
                            $"{item.Percent}% — {item.Message}");
                    });

            using var cancellation =
                new CancellationTokenSource(
                    TimeSpan.FromMinutes(60));

            var result =
                await _databaseDeploymentService.DeployAsync(
                    settings,
                    sshPassword,
                    selectedJob.OutputPath,
                    progress,
                    cancellation.Token);

            selectedJob.DatabaseName =
                result.DatabaseName;

            selectedJob.DatabaseUser =
                result.DatabaseUser;

            JobsGrid.Items.Refresh();

            var creationText =
                result.DatabaseWasCreated
                    ? "БД была создана."
                    : "Использована уже существующая БД.";

            var message =
                $"Этап 4 завершён для {selectedJob.Domain}.\n\n" +
                $"База: {result.DatabaseName}\n" +
                $"Пользователь: {result.DatabaseUser}\n" +
                $"{creationText}\n" +
                $"SQL импортирован: {Path.GetFileName(result.SqlFile)}";

            Build4ProgressBar.Value = 100;
            Build4StatusTextBlock.Text =
                message.Replace('\n', ' ');

            SetStatus(
                $"{selectedJob.Domain}: этап 4 завершён.");

            AddLog(
                "INFO",
                selectedJob.Domain,
                $"БД {result.DatabaseName} готова; " +
                "SQL импортирован.");

            MessageBox.Show(
                this,
                message,
                "Сборка 4 — успешно",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (Exception exception)
        {
            var message =
                SensitiveDataRedactor.Redact(
                    exception.Message);

            Build4StatusTextBlock.Text = message;
            SetStatus(message);

            AddLog(
                "ERROR",
                selectedJob.Domain,
                message);

            MessageBox.Show(
                this,
                message,
                "Ошибка этапа 4",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        finally
        {
            sshPassword = string.Empty;

            SetBuild3Busy(false);
            DeployDatabaseButton.IsEnabled = true;
        }
    }
}