# sogode.com and its subdomains on ruby. Managed in homelab/wordpress;
# installed by wordpress/scripts/install-ruby.sh, which replaces the live file.
#
##
# You should look at the following URL's in order to grasp a solid understanding
# of Nginx configuration files in order to fully unleash the power of Nginx.
# https://www.nginx.com/resources/wiki/start/
# https://www.nginx.com/resources/wiki/start/topics/tutorials/config_pitfalls/
# https://wiki.debian.org/Nginx/DirectoryStructure
#

# Default server configuration
# Set the `immutable` cache control options only for assets with a cache busting `v` argument
map $arg_v $asset_immutable {
	"" "";
	default "immutable";
}

server {
	listen 80;
	listen [::]:80;
	server_name sogode.com www.sogode.com;

	location / {
		#return 302 https://www.linkedin.com/company/sogode/;
		return 302 https://sogode.com/;
	}

	location /.well-known/acme-challenge/ {
		alias /var/www/letsencrypt/sogode.com/acme-challenge/;
	}
}

server {
	# SSL configuration
	#
	listen 443 ssl;
	listen [::]:443 ssl;
	http2 on;

	server_name sogode.com www.sogode.com;
	access_log /var/log/nginx/sogode.com-https-access.log;
	error_log  /var/log/nginx/sogode.com-https-error.log;
    ssl_certificate /etc/letsencrypt/live/sogode.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/sogode.com/privkey.pem; # managed by Certbot
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

	# HSTS (ngx_http_headers_module is required) (63072000 seconds)
	add_header Strict-Transport-Security "max-age=63072000" always;
	
	# # OCSP stapling
	# ssl_stapling on;
	# ssl_stapling_verify on;
	
	location / {
# 		# Temporary redirect to LinkedIn, unless over WireGuard
# 		if ($wg_client = 0) {
# 			return 302 https://www.linkedin.com/company/sogode/;
# 		}

		proxy_pass http://localhost:19080;
	
		proxy_set_header Host			$host;
		proxy_set_header X-Real-IP		$remote_addr;
		proxy_set_header X-Forwarded-For	$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto	$scheme;
		proxy_set_header X-Forwarded-Host	$host;
	
		proxy_http_version			1.1;
		proxy_set_header Upgrade		$http_upgrade;
		proxy_set_header Connection		$connection_upgrade;
	
		proxy_read_timeout 300s;

		# Login and XML-RPC are for the owner only, over the VPN or the tunnels;
		# from the internet both were password guessing. Jetpack runs over
		# XML-RPC and is given up with it. Nested here to inherit the
		# proxy_set_header lines above; proxy_pass is not inherited.
		location = /wp-login.php {
			include snippets/home-lan-allow.conf;
			deny all;
			proxy_pass http://localhost:19080;
		}

		location = /xmlrpc.php {
			include snippets/home-lan-allow.conf;
			deny all;
			proxy_pass http://localhost:19080;
		}
	}
}

server {
	listen 80;
	listen [::]:80;
	server_name social.sogode.com;

	location / {
		return 301 https://social.sogode.com$request_uri;
	}

	location /.well-known/acme-challenge/ {
		alias /var/www/letsencrypt/$server_name/acme-challenge/;
	}

	location /.well-known/ {
		alias /var/www/mta-sts/$server_name/;
	}
}

server {
	# SSL configuration
	#
	listen 443 ssl;
	http2 on;

	server_name social.sogode.com;
	access_log /var/log/nginx/social.sogode.com-https-access.log;
	error_log  /var/log/nginx/social.sogode.com-https-error.log;
    ssl_certificate /etc/letsencrypt/live/sogode.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/sogode.com/privkey.pem; # managed by Certbot
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

	# HSTS (ngx_http_headers_module is required) (63072000 seconds)
	add_header Strict-Transport-Security "max-age=63072000" always;
	
	# # OCSP stapling
	# ssl_stapling on;
	# ssl_stapling_verify on;
	
	# The settings allows you to optimize the HTTP2 bandwidth.
	# See https://blog.cloudflare.com/delivering-http-2-upload-speed-improvements/
	# for tuning hints
	client_body_buffer_size 512k;

	root /var/www/social.sogode.com;

	location / {
	}

	# Deny all attempts to access hidden files such as .htaccess, .htpasswd, .DS_Store (Mac).
	# Keep logging the requests to parse later (or to pass to firewall utilities such as fail2ban)
	location ~ /\. {
		deny all;
	}

	location = /favicon.ico {
		log_not_found off;
		access_log off;
	}

	location = /robots.txt {
		allow all;
		log_not_found off;
	}
}

server {
	listen 80;
	listen [::]:80;
	server_name mta-sts.sogode.com;

	location /.well-known {
		alias /var/www/mta-sts/sogode.com;
	}

	location /.well-known/acme-challenge/ {
		alias /var/www/letsencrypt/$server_name/acme-challenge/;
	}

	location = /favicon.ico {
		log_not_found off;
		access_log off;
	}

	location = /robots.txt {
		allow all;
		log_not_found off;
	}
}

server {
	listen 80;
	listen [::]:80;
	server_name marketing.sogode.com;

	location /.well-known/acme-challenge/ {
		alias /var/www/letsencrypt/$server_name/acme-challenge/;
		index index.html;
	}

	location /.well-known/ {
		alias /var/www/mta-sts/$server_name/;
	}
}

server {
	listen 80;
	listen [::]:80;
	server_name mta-sts.marketing.sogode.com;

	location /.well-known/acme-challenge/ {
		alias /var/www/letsencrypt/$server_name/acme-challenge/;
	}

	location /.well-known/ {
		alias /var/www/mta-sts/marketing.sogode.com/;
	}
}

server {
	listen 443 ssl;
	http2 on;
	server_name mta-sts.marketing.sogode.com;

	ssl_certificate /etc/letsencrypt/live/sogode.com/fullchain.pem; # managed by Certbot
	ssl_certificate_key /etc/letsencrypt/live/sogode.com/privkey.pem; # managed by Certbot
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

	# HSTS (ngx_http_headers_module is required) (63072000 seconds)
	add_header Strict-Transport-Security "max-age=63072000" always;
	
	# # OCSP stapling
	# ssl_stapling on;
	# ssl_stapling_verify on;
	
	client_body_buffer_size 512k;

	location /.well-known/ {
		alias /var/www/mta-sts/marketing.sogode.com/;
	}

}

server {
	listen 443 ssl;
	http2 on;
	server_name mta-sts.sogode.com;

	access_log /var/log/nginx/mta-sts.sogode.com-https-access.log;
	error_log  /var/log/nginx/mta-sts.sogode.com-https-error.log;

	ssl_certificate /etc/letsencrypt/live/sogode.com/fullchain.pem; # managed by Certbot
	ssl_certificate_key /etc/letsencrypt/live/sogode.com/privkey.pem; # managed by Certbot
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

	# HSTS (ngx_http_headers_module is required) (63072000 seconds)
	add_header Strict-Transport-Security "max-age=63072000" always;
	
	# # OCSP stapling
	# ssl_stapling on;
	# ssl_stapling_verify on;
	
	# The settings allows you to optimize the HTTP2 bandwidth.
	# See https://blog.cloudflare.com/delivering-http-2-upload-speed-improvements/
	# for tuning hints
	client_body_buffer_size 512k;

	location /.well-known {
		alias /var/www/mta-sts/sogode.com;
	}

	location = /favicon.ico {
		log_not_found off;
		access_log off;
	}

	location = /robots.txt {
		allow all;
		log_not_found off;
	}
}
