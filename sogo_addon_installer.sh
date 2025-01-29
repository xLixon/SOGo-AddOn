#!/bin/bash

# Prüfe, ob ein Pfad übergeben wurde
if [ -z "$1" ]; then
  echo "Bitte gib den Installationspfad von Mailcow an."
  exit 1
fi

MAILCOW_DIR="$1"

# Überprüfen, ob das Verzeichnis existiert
if [ ! -d "$MAILCOW_DIR" ]; then
  echo "Das angegebene Verzeichnis existiert nicht: $MAILCOW_DIR"
  exit 1
fi

# Zielverzeichnis erstellen
TARGET_DIR="$MAILCOW_DIR/data/web/sogossologin"
mkdir -p "$TARGET_DIR"

# Datei sogo-auth.php erstellen und mit Inhalt füllen
cat > "$TARGET_DIR/sogo-auth.php" << 'EOF'
<?php
session_start();
$session_var_user_allowed = 'sogo-sso-user-allowed';
$session_var_pass = 'sogo-sso-pass';

function checkTokenExists($pdo, $username, $token): bool
{
    try {
        $stmt = $pdo->prepare("SELECT * FROM `sogo_sso_tokens` WHERE `username` = :username AND `token` = :token");
        $stmt->bindParam(':username', $username);
        $stmt->bindParam(':token', $token);
        $stmt->execute();
        return $stmt->rowCount() === 1;
    } catch (PDOException $e) {
        return false;
    }
}

if (isset($_GET['email']) && $_GET['token']) {
    require_once $_SERVER['DOCUMENT_ROOT'] . '/inc/prerequisites.inc.php';
    if (checkTokenExists($pdo, $_GET['email'], $_GET['token'])) {
        try {
            $sogo_sso_pass = file_get_contents("/etc/sogo-sso/sogo-sso.pass");
            $_SESSION[$session_var_user_allowed][] = $_GET['email'];
            $_SESSION[$session_var_pass] = $sogo_sso_pass;
            $stmt = $pdo->prepare("REPLACE INTO sasl_log (`service`, `app_password`, `username`, `real_rip`) VALUES ('SSO', 0, :username, :remote_addr)");
            $stmt->execute([
                ':username' => $_GET['email'],
                ':remote_addr' => $_SERVER['REMOTE_ADDR'] ?? $_SERVER['HTTP_X_REAL_IP']
            ]);
        } catch (PDOException $e) {
            echo $e->getMessage();
        }

        header("Location: /SOGo/so/{$_GET['email']}");
    } else {
        http_response_code(401);
    }
}

header("X-User: ");
header("X-Auth: ");
header("X-Auth-Type: ");
EOF

# Datei sogo-tokengenerate.php erstellen und mit Inhalt füllen
cat > "$TARGET_DIR/sogo-tokengenerate.php" << 'EOF'
<?php
require_once $_SERVER['DOCUMENT_ROOT'] . '/inc/prerequisites.inc.php';
$_POST = json_decode(file_get_contents('php://input'), true);

function createIfTableDoesntExist($pdo)
{
    try {
        $stmt = $pdo->prepare("CREATE TABLE IF NOT EXISTS `sogo_sso_tokens` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `username` TEXT NOT NULL,
            `token` TEXT NOT NULL
        )");
        $stmt->execute();
    } catch (PDOException $e) {
        echo $e->getMessage();
    }
}

function writeTokenToDB($username, $token, $pdo): bool
{
    try {
        $stmt = $pdo->prepare("INSERT INTO `sogo_sso_tokens` (`username`, `token`) VALUES (:username, :token)");
        $stmt->bindParam(':username', $username);
        $stmt->bindParam(':token', $token);
        return $stmt->execute();
    } catch (PDOException $e) {
        echo $e->getMessage();
        return false;
    }
}

function generateToken($username): string
{
    return md5(base64_encode($username) . random_bytes(16) . md5(time()));
}

function getApiKey($pdo)
{
    try {
        $stmt = $pdo->prepare("SELECT `api_key` FROM `api` LIMIT 1");
        $stmt->execute();
        return $stmt->fetchColumn();
    } catch (PDOException $e) {
        return null;
    }
}

if (isset($_POST['username']) && isset($_POST['apikey'])) {
    if ($_POST['apikey'] == getApiKey($pdo)) {
        $username = $_POST['username'];
        $token = generateToken($username);
        createIfTableDoesntExist($pdo);
        writeTokenToDB($username, $token, $pdo);
        echo json_encode([
            "success" => true,
            "username" => $username,
            "token" => $token
        ]);
    }
}
EOF

echo "Die Dateien wurden erfolgreich im Verzeichnis '$TARGET_DIR' erstellt."
