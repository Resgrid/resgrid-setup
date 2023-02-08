#!/bin/bash

trap exit TERM;
while :;
do
     certbot renew;
     cp -f /etc/letsencrypt/live/$NGINX_RESGRID_WEB_URL/*.* /etc/letsencrypt/web/;
     cp -f /etc/letsencrypt/live/$NGINX_RESGRID_API_URL/*.* /etc/letsencrypt/api/;
     cp -f /etc/letsencrypt/live/$NGINX_RESGRID_EVENTS_URL/*.* /etc/letsencrypt/events/;
     sleep 12h & wait $${!};
done  
