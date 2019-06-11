#    __                 __           __     ___  __          _
#   / /  ___  ___ ____ / /____ ____ / /    / _ \/ /_ _____ _(_)__
#  / /__/ _ \/ _ `(_-</ __/ _ `(_-</ _ \  / ___/ / // / _ `/ / _ \
# /____/\___/\_, /___/\__/\_,_/___/_//_/ /_/  /_/\_,_/\_, /_/_//_/
#           /___/                                    /___/
#
FROM jruby

ARG PLUGIN_NAME=logstash-output-jdbc
ARG LOGSTASH_VERSION=7.1.1
ARG PSQL_JAR_VERSION=42.2.5
ARG MYSQL_CONNECTOR_JAR_VERSION=5.1.47
ARG SQLITE_JDBC_JAR_VERSION=3.27.2.1
#############################################################################
# Override any of the above variables at build time                         #
# i.e `docker build -t jdbc --build-arg LOGSTASH_VERSION=7.0.0 .`           #
#############################################################################

WORKDIR /usr/src/plugin

# install dependencies
COPY Gemfile Gemfile.lock Rakefile ${PLUGIN_NAME}.gemspec ./
RUN bundle install

# install test databases
RUN apt-get update && \
    apt-get install mysql-server postgresql-client postgresql -qq -y && \
    service mysql start && \
    mysql -e "CREATE DATABASE logstash; GRANT ALL PRIVILEGES ON logstash.* to 'logstash'@'localhost' IDENTIFIED BY 'logstash'; FLUSH PRIVILEGES;" && \
    useradd logstash && \
    service postgresql start && \
    su -m postgres -c "createuser -w logstash" && \
    su -m postgres -c "createdb logstash" && \
    su -m postgres -c "psql -c 'GRANT ALL PRIVILEGES ON DATABASE logstash TO logstash'"

# build plugin gem
COPY lib lib
COPY spec spec
RUN bundle exec rake install_jars && \
    bundle exec rspec && \
    gem build ${PLUGIN_NAME}.gemspec && \
    grep s.version ${PLUGIN_NAME}.gemspec | awk '{print $3}' | tr -d "'" > GEM_VERSION

# install logstash
RUN cd ../ && \
    curl -O https://artifacts.elastic.co/downloads/logstash/logstash-${LOGSTASH_VERSION}.tar.gz && \
    tar xzf logstash-${LOGSTASH_VERSION}.tar.gz && \
    mv logstash-${LOGSTASH_VERSION} logstash && \
    rm -rf logstash-* && \
    cd logstash && \
    bin/logstash-plugin install /usr/src/plugin/${PLUGIN_NAME}-$(cat /usr/src/plugin/GEM_VERSION).gem && \
    bin/logstash-plugin list | grep ${PLUGIN_NAME}

ENV LOGSTASH_PATH /usr/src/logstash

# download client jars for testing
RUN cd /tmp && \
    curl -o /tmp/postgres.jar https://jdbc.postgresql.org/download/postgresql-${PSQL_JAR_VERSION}.jar && \
    curl -L -O https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-${MYSQL_CONNECTOR_JAR_VERSION}.tar.gz && \
    tar xzf mysql-connector-java-${MYSQL_CONNECTOR_JAR_VERSION}.tar.gz && \
    mv mysql-connector-java-${MYSQL_CONNECTOR_JAR_VERSION}/mysql-connector-java-${MYSQL_CONNECTOR_JAR_VERSION}.jar /tmp/mysql.jar && \
    rm -rf mysql-connector-* && \
    curl -L -o /tmp/sqlite.jar https://bitbucket.org/xerial/sqlite-jdbc/downloads/sqlite-jdbc-${SQLITE_JDBC_JAR_VERSION}.jar

#######################################################################################################################################################################################################################################
# This will run logstash and accept JSON input from stdin.
# Notice the output.jdbc.connection_string arguemnt ('jdbc:postgresql://postgres:5432/winston?user=postgres&password=postgres')
# is accessing an external resource. For this to work, the container needs to have access to the docker host network.
#
# Build, Run, Stdin Example:
#   docker build -t jdbc . && docker run --network=host --name jdbc -it jdbc
#   {"anonymous_user": "d7c0d187-aec5-46e6-9384-6861cca88e7c", "app_name": "Web App", "event": "Hi - Dan", "user_id": "268273", "user_uid": "40698fbd-be30-5e95-8f2a-9896bce7230f"}
#######################################################################################################################################################################################################################################
CMD ["/usr/src/logstash/bin/logstash", "-e", "input { stdin { codec => 'json' } } output { jdbc { connection_string => 'jdbc:localhost://postgres:5432/logstash?user=logstash' statement => [ 'INSERT INTO users (last_name, first_name) VALUES(?, ?)', '[app_name]', '[event]' ] driver_jar_path => '/tmp/postgres.jar' } stdout { codec => rubydebug } }"]

# Other helpful docker examples
# docker build -t jdbc .                # build image
# docker run -d --name jdbc -t jdbc     # run container detatched (might want to comment out CMD before)
# docker exec -it jdbc bash             # bash into container
# docker stop jdbc && docker rm jdbc    # stop and remove container
# docker start -a jdbc                  # start and attatch to container