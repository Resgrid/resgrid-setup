FROM mcr.microsoft.com/azure-sql-edge

WORKDIR /usr/src/app

COPY create-databases.sql /usr/src/app/create-databases.sql
COPY initdbs.sh /usr/src/app/initdbs.sh
COPY entrypoint.sh /usr/src/app/entrypoint.sh

EXPOSE 1433

CMD /bin/bash ./entrypoint.sh
