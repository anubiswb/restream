#!/bin/bash

# طلب الدومين والبريد الإلكتروني
read -p "Enter your domain name (e.g., example.com): " DOMAIN
read -p "Enter your email address for SSL certificate: " EMAIL

# تحديث النظام
sudo apt update
sudo apt upgrade -y

# تثبيت Nginx، FFmpeg، وCertbot
sudo apt install -y nginx ffmpeg libnginx-mod-rtmp php php-fpm certbot python3-certbot-nginx

# إعداد تكوين Nginx مع وحدة RTMP
sudo tee /etc/nginx/nginx.conf > /dev/null <<EOF
rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        application live {
            live on;
            record off;

            # HLS configuration
            hls on;
            hls_path /mnt/hls/;
            hls_fragment 3;
            hls_playlist_length 60;
        }
    }
}

http {
    server {
        listen 80;
        server_name $DOMAIN;
        root /var/www/html;

        location /hls {
            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            alias /mnt/hls/;
            add_header Cache-Control no-cache;
        }
    }
}
EOF

# إنشاء مسار HLS
sudo mkdir -p /mnt/hls
sudo chown -R www-data:www-data /mnt/hls

# إعادة تشغيل Nginx
sudo systemctl restart nginx

# إعداد شهادة SSL باستخدام Certbot
sudo certbot --nginx -d $DOMAIN -m $EMAIL --agree-tos --non-interactive

# إعداد ملفات PHP
sudo mkdir -p /var/www/html
cat << 'EOF' | sudo tee /var/www/html/index.php > /dev/null
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Live Stream Manager</title>
</head>
<body>
    <h1>Live Stream Manager</h1>
    <form action="stream.php" method="post">
        <label for="source">Enter M3U8 URL:</label>
        <input type="text" id="source" name="source" required>
        <input type="submit" value="Start Stream">
    </form>

    <h2>Active Streams</h2>
    <ul>
        <?php
        $streams = file_exists('streams.json') ? json_decode(file_get_contents('streams.json'), true) : [];
        foreach ($streams as $key => $stream) {
            echo "<li>Source: {$stream['source']} | Output: {$stream['output']} 
                  <form action='stream.php' method='post' style='display:inline;'>
                      <input type='hidden' name='action' value='delete'>
                      <input type='hidden' name='pid' value='{$stream['pid']}'>
                      <input type='submit' value='Delete'>
                  </form>
                  </li>";
        }
        ?>
    </ul>
</body>
</html>
EOF

cat << 'EOF' | sudo tee /var/www/html/stream.php > /dev/null
<?php
if ($_SERVER["REQUEST_METHOD"] == "POST") {
    $streams = file_exists('streams.json') ? json_decode(file_get_contents('streams.json'), true) : [];

    if (isset($_POST['source'])) {
        // إضافة بث جديد
        $source = $_POST['source'];
        $output_path = "/mnt/hls/stream_" . uniqid();
        $output_playlist = "https://$DOMAIN/hls/stream_" . uniqid() . ".m3u8";

        // تشغيل FFmpeg في الخلفية لتوليد ملفات HLS
        $command = "ffmpeg -re -i \"$source\" -c:v libx264 -c:a aac -f hls -hls_time 10 -hls_list_size 10 -hls_wrap 10 -start_number 1 \"$output_path.m3u8\" > /dev/null 2>&1 & echo $!";
        $pid = exec($command);

        // تخزين معلومات البث
        $streams[] = ['source' => $source, 'output' => $output_playlist, 'pid' => $pid];
        file_put_contents('streams.json', json_encode($streams));
    } elseif (isset($_POST['action']) && $_POST['action'] === 'delete' && isset($_POST['pid'])) {
        // حذف بث
        $pid = intval($_POST['pid']);

        // إنهاء عملية FFmpeg
        exec("kill $pid");

        // إزالة البث من قائمة البثوث
        foreach ($streams as $key => $stream) {
            if ($stream['pid'] == $pid) {
                unset($streams[$key]);
                break;
            }
        }
        file_put_contents('streams.json', json_encode(array_values($streams)));
    }

    header("Location: index.php");
    exit();
}
?>
EOF

# إعداد ملف streams.json
sudo touch /var/www/html/streams.json
sudo chown www-data:www-data /var/www/html/streams.json

echo "تم التثبيت والتكوين بنجاح. يمكنك الآن الوصول إلى صفحة الإدارة عبر https://$DOMAIN"
