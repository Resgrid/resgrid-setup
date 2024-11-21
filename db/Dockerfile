FROM mcr.microsoft.com/mssql/server:2022-CU12-ubuntu-22.04

WORKDIR /usr/src/app

COPY create-databases.sql /usr/src/app/create-databases.sql
COPY initdbs.sh /usr/src/app/initdbs.sh
COPY entrypoint.sh /usr/src/app/entrypoint.sh

EXPOSE 1433

CMD /bin/bash ./entrypoint.sh
