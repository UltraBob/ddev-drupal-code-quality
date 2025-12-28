<?php
// #ddev-generated

declare(strict_types=1);

function truthy(?string $value): bool
{
    if ($value === null) {
        return false;
    }
    $value = strtolower(trim($value));
    return in_array($value, ['1', 'true', 'yes', 'on'], true);
}

function strip_generated_header(string $content): string
{
    if (strpos($content, '#ddev-generated') !== 0) {
        return $content;
    }
    $content = preg_replace('/\A#ddev-generated\s*\R/', '', $content, 1);
    return $content ?? $content;
}

function ensure_dir(string $dir): void
{
    if (!is_dir($dir)) {
        mkdir($dir, 0775, true);
    }
}

function files_equal(string $target, string $content): bool
{
    if (!file_exists($target)) {
        return false;
    }
    $existing = file_get_contents($target);
    if ($existing === false) {
        return false;
    }
    return hash('sha256', $existing) === hash('sha256', $content);
}

function diff_available(): bool
{
    $path = trim((string) shell_exec('command -v diff'));
    return $path !== '' && is_executable($path);
}

function show_diff(string $target, string $content): void
{
    if (!diff_available()) {
        fwrite(STDOUT, "Diff not available on this system.\n");
        return;
    }
    $tmp = tempnam(sys_get_temp_dir(), 'dcq-src-');
    if ($tmp === false) {
        fwrite(STDOUT, "Unable to create temp file for diff.\n");
        return;
    }
    file_put_contents($tmp, $content);
    $cmd = sprintf('diff -u %s %s', escapeshellarg($target), escapeshellarg($tmp));
    $output = shell_exec($cmd);
    if ($output !== null) {
        fwrite(STDOUT, $output);
    }
    @unlink($tmp);
}

function backup_file(string $path): string
{
    $suffix = '.bak';
    $backup = $path . $suffix;
    $index = 1;
    while (file_exists($backup)) {
        $backup = $path . $suffix . '.' . $index;
        $index += 1;
    }
    if (!copy($path, $backup)) {
        throw new RuntimeException("Failed to create backup for $path");
    }
    return $backup;
}

function prompt_choice(string $path, bool $warnParity): string
{
    if ($warnParity) {
        fwrite(STDOUT, "Skipping this file may reduce CI parity for your local tooling.\n");
    }
    fwrite(STDOUT, "Conflict at $path. Choose: [r]eplace (backup), [s]kip, [a]bort, [ra] replace all, [sa] skip all: ");
    $answer = trim((string) fgets(STDIN));
    if ($answer === '') {
        return 's';
    }
    return $answer;
}

$cwd = getcwd();
if ($cwd === false) {
    fwrite(STDERR, "Unable to determine working directory.\n");
    exit(1);
}

$appRoot = getenv('DDEV_APPROOT');
if ($appRoot === false || $appRoot === '') {
    $appRoot = dirname($cwd);
}
$assetsRoot = $cwd . '/dcq-assets';
if (!is_dir($assetsRoot)) {
    fwrite(STDERR, "dcq-assets directory not found at $assetsRoot.\n");
    exit(1);
}

$shimDirEnv = getenv('DCQ_SHIM_DIR') ?: 'tooling/bin';
$shimDir = $shimDirEnv;
if (!preg_match('/^\//', $shimDir)) {
    $shimDir = rtrim($appRoot, '/') . '/' . ltrim($shimDir, '/');
}
$appRootCheck = rtrim($appRoot, '/');
$shimDirCheck = rtrim($shimDir, '/');
if ($shimDirCheck !== $appRootCheck && strpos($shimDirCheck, $appRootCheck . '/') !== 0) {
    fwrite(STDERR, "DCQ_SHIM_DIR must be inside the project root ($appRoot).\n");
    exit(1);
}

$nonInteractive = truthy(getenv('DDEV_NONINTERACTIVE') ?: getenv('DCQ_NONINTERACTIVE') ?: null);
$installMode = strtolower(trim((string) getenv('DCQ_INSTALL_MODE')));
if ($nonInteractive && $installMode === '') {
    $installMode = 'replace';
}
$replaceAll = $installMode === 'replace';
$skipAll = $installMode === 'skip';
$abortOnConflict = $installMode === 'abort';

$iterator = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($assetsRoot, FilesystemIterator::SKIP_DOTS)
);

fwrite(STDOUT, "Installing Drupal CI parity assets...\n");

foreach ($iterator as $file) {
    if (!$file->isFile()) {
        continue;
    }
    $source = $file->getPathname();
    $rel = substr($source, strlen($assetsRoot) + 1);

    $target = rtrim($appRoot, '/') . '/' . $rel;
    if (strpos($rel, 'tooling/bin/') === 0) {
        $target = rtrim($shimDir, '/') . '/' . substr($rel, strlen('tooling/bin/'));
    }

    $content = file_get_contents($source);
    if ($content === false) {
        fwrite(STDERR, "Unable to read $source.\n");
        exit(1);
    }
    $content = strip_generated_header($content);

    if (file_exists($target)) {
        if (files_equal($target, $content)) {
            fwrite(STDOUT, "OK: $target already matches.\n");
            continue;
        }
        if ($skipAll) {
            fwrite(STDOUT, "SKIP: $target (existing file).\n");
            continue;
        }
        if ($replaceAll) {
            $backup = backup_file($target);
            fwrite(STDOUT, "BACKUP: $backup\n");
        } elseif ($abortOnConflict) {
            fwrite(STDERR, "ABORT: conflict at $target.\n");
            exit(1);
        } else {
            show_diff($target, $content);
            $choice = prompt_choice($target, true);
            $choice = strtolower(trim($choice));
            if ($choice === 'r' || $choice === 'replace') {
                $backup = backup_file($target);
                fwrite(STDOUT, "BACKUP: $backup\n");
            } elseif ($choice === 's' || $choice === 'skip') {
                fwrite(STDOUT, "SKIP: $target (existing file).\n");
                continue;
            } elseif ($choice === 'a' || $choice === 'abort') {
                fwrite(STDERR, "ABORT: conflict at $target.\n");
                exit(1);
            } elseif ($choice === 'ra' || $choice === 'rall' || $choice === 'replace all') {
                $replaceAll = true;
                $backup = backup_file($target);
                fwrite(STDOUT, "BACKUP: $backup\n");
            } elseif ($choice === 'sa' || $choice === 'sall' || $choice === 'skip all') {
                $skipAll = true;
                fwrite(STDOUT, "SKIP: $target (existing file).\n");
                continue;
            } else {
                fwrite(STDOUT, "Unknown choice. Skipping $target.\n");
                continue;
            }
        }
    }

    ensure_dir(dirname($target));
    if (file_put_contents($target, $content) === false) {
        fwrite(STDERR, "Failed to write $target.\n");
        exit(1);
    }
    if (strpos($target, $shimDir) === 0 || $file->isExecutable()) {
        @chmod($target, 0755);
    }
    fwrite(STDOUT, "WRITE: $target\n");
}

fwrite(STDOUT, "Done.\n");
