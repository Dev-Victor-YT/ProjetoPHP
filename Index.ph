<?php

// Carrega os dados de login a partir de uma URL remota
$logins_url = 'https://rede-storagecloud.github.io/StorageCloud/index.json';
$json_data = @file_get_contents($logins_url);

if (!$json_data) {
    die("Erro ao acessar o JSON remoto.");
}

$logins = json_decode($json_data, true);
if (!$logins) {
    die("Erro ao decodificar JSON.");
}

// Substitui host e senha por valores fixos
$hostFixo = 'ftpupload.net';
$senhaFixa = 'Senha123456@';
foreach ($logins as &$cfg) {
    $cfg['host'] = $hostFixo;
    $cfg['pass'] = $senhaFixa;
}
unset($cfg);

// Função para verificar espaço disponível em servidor FTP
function espacoDisponivel($conn) {
    $resposta = @ftp_raw($conn, "STAT /");
    if (!$resposta) return false;

    foreach ($resposta as $linha) {
        if (preg_match('/(\d+)\s+Kbytes\s+free/', $linha, $m)) {
            return $m[1] * 1024;
        }
    }
    return false;
}

// Função para localizar servidor com determinado caminho/arquivo
function localizarServidorComArquivo($relPath, $logins) {
    foreach ($logins as $cfg) {
        $c = @ftp_connect($cfg['host']);
        if (!$c || !@ftp_login($c, $cfg['user'], $cfg['pass'])) {
            @ftp_close($c);
            continue;
        }
        ftp_pasv($c, true);

        $raizDetectada = false;
        foreach (['public_html','www','htdocs'] as $d) {
            if (@ftp_chdir($c, $d)) {
                $raizDetectada = true;
                break;
            }
        }

        if (!$raizDetectada) {
            ftp_close($c);
            continue;
        }

        $pastas = explode('/', $relPath);
        $arquivo = array_pop($pastas);
        $existe = true;
        foreach ($pastas as $pasta) {
            if (!@ftp_chdir($c, $pasta)) {
                $existe = false;
                break;
            }
        }

        if ($existe && @ftp_size($c, $arquivo) > -1) {
            ftp_close($c);
            return $cfg;
        }

        ftp_close($c);
    }
    return false;
}

// ========== MODO 1: ENVIO DE ARQUIVO ========== //
if (isset($_FILES['file']) && isset($_POST['punch'])) {
    $arquivo_temp = $_FILES['file']['tmp_name'];
    $punch = trim($_POST['punch'], '/\\');
    $relPath = str_replace('\\', '/', $punch);
    $tamanhoArquivo = filesize($arquivo_temp);

    $destino = localizarServidorComArquivo($relPath, $logins);
    if (!$destino) {
        foreach ($logins as $cfg) {
            $c = @ftp_connect($cfg['host']);
            if (!$c || !@ftp_login($c, $cfg['user'], $cfg['pass'])) {
                @ftp_close($c);
                continue;
            }
            ftp_pasv($c, true);

            $raizDetectada = false;
            foreach (['public_html','www','htdocs'] as $d) {
                if (@ftp_chdir($c, $d)) {
                    $raizDetectada = true;
                    break;
                }
            }

            if (!$raizDetectada) {
                ftp_close($c);
                continue;
            }

            $esp = espacoDisponivel($c);
            if ($esp !== false && $esp < $tamanhoArquivo) {
                ftp_close($c);
                continue;
            }

            ftp_close($c);
            $destino = $cfg;
            break;
        }
    }

    if (!$destino) {
        die("Erro: nenhum servidor disponível com espaço suficiente.");
    }

    // Conecta e envia
    $c = @ftp_connect($destino['host']);
    if (!$c || !@ftp_login($c, $destino['user'], $destino['pass'])) {
        @ftp_close($c);
        die("Falha ao conectar no servidor de destino.");
    }
    ftp_pasv($c, true);

    $raizDetectada = false;
    foreach (['public_html','www','htdocs'] as $d) {
        if (@ftp_chdir($c, $d)) {
            $raizDetectada = true;
            break;
        }
    }
    if (!$raizDetectada) {
        ftp_close($c);
        die("Não foi possível localizar a raiz do FTP.");
    }

    $pastas = explode('/', $relPath);
    $arquivoFinal = array_pop($pastas);
    foreach ($pastas as $pasta) {
        if (!@ftp_chdir($c, $pasta)) {
            ftp_mkdir($c, $pasta);
            ftp_chdir($c, $pasta);
        }
    }

    if (ftp_put($c, $arquivoFinal, $arquivo_temp, FTP_BINARY)) {
        $baseUrl = 'https://' . rtrim($destino['domain'], '/');
        $urlFinal = $baseUrl . '/' . $relPath;
        echo "Arquivo enviado com sucesso para:\n$urlFinal\n";

        $host = $_SERVER['HTTP_HOST'];
        $url_php = "https://{$host}/" . $relPath;
        echo "URL pública de download:\n$url_php\n";
    } else {
        echo "Falha ao enviar o arquivo via FTP.\n";
    }
    ftp_close($c);
    exit;
}

// ========== MODO 2: LOCALIZAÇÃO DE ARQUIVO E FORÇAR DOWNLOAD ========== //
$request_uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$relPath = trim($request_uri, '/');

if (!$relPath) {
    http_response_code(400);
    die("URL inválida. Caminho não especificado.");
}

$destino = localizarServidorComArquivo($relPath, $logins);
if ($destino) {
    $urlArquivo = 'https://' . rtrim($destino['domain'], '/') . '/' . $relPath;

    $conteudo = @file_get_contents($urlArquivo);
    if ($conteudo === false) {
        http_response_code(500);
        die("Erro ao obter o conteúdo do arquivo.");
    }

    header('Content-Description: File Transfer');
    header('Content-Type: application/octet-stream');
    header('Content-Disposition: attachment; filename="' . basename($relPath) . '"');
    header('Content-Length: ' . strlen($conteudo));
    header('Cache-Control: must-revalidate');
    header('Pragma: public');
    header('Expires: 0');

    echo $conteudo;
    exit;
}

http_response_code(404);
echo "Arquivo não encontrado em nenhum servidor.";