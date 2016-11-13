set -e
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
export DEBIAN_FRONTEND=noninteractive

EBS_MOUNT="/mnt"
PG_MAJOR="9.3"
PG_DATA_DIR="${EBS_MOUNT}/postgresql"
PGDATABASE="osm"
PGUSER="osm"
PGPASSWORD="osmpassword"
export PGUSER
export PGPASSWORD
OSM2PGSQL_CACHE=$(free -m | grep -i 'mem:' | sed 's/[ \t]\+/ /g' | cut -f4,7 -d' ' | tr ' ' '+' | bc)
OSM2PGSQL_PROCS=$(grep -c 'model name' /proc/cpuinfo)

apt-add-repository -y ppa:tilezen
apt-get -qq update
apt-get -qq install -y git unzip \
    postgresql-${PG_MAJOR} postgresql-contrib postgis postgresql-${PG_MAJOR}-postgis-2.1 \
    build-essential autoconf libtool pkg-config \
    python-dev python-virtualenv libgeos-dev libpq-dev python-pip python-pil libmapnik2.2 libmapnik-dev mapnik-utils python-mapnik \
    osm2pgsql

# Move the postgresql data to the EBS volume
mkdir -p $PG_DATA_DIR
/etc/init.d/postgresql stop
sed -i "s/^data_directory = .*$/# data_directory = /" /etc/postgresql/$PG_MAJOR/main/postgresql.conf
echo "data_directory = '${PG_DATA_DIR}/${PG_MAJOR}/main'" >> /etc/postgresql/$PG_MAJOR/main/postgresql.conf
cp -a /var/lib/postgresql/$PG_MAJOR $PG_DATA_DIR
chown -R postgres:postgres $PG_DATA_DIR
/etc/init.d/postgresql start

# Create database and user
sudo -u postgres psql -c "CREATE ROLE ${PGUSER} WITH NOSUPERUSER LOGIN UNENCRYPTED PASSWORD '${PGPASSWORD}';"
sudo -u postgres psql -c "CREATE DATABASE ${PGDATABASE} WITH OWNER ${PGUSER};"
sudo -u postgres psql -d $PGDATABASE -c 'CREATE EXTENSION postgis; CREATE EXTENSION hstore;'

# Download the planet
wget --quiet --directory-prefix $EBS_MOUNT --timestamping \
    http://planet.openstreetmap.org/pbf/planet-latest.osm.pbf

# Import the planet
SOURCE_DIR="${EBS_MOUNT}/vector-datasource"
git clone https://github.com/tilezen/vector-datasource.git $SOURCE_DIR

osm2pgsql --create --slim --cache 27000 --hstore-all \
    --host localhost \
    --number-processes $OSM2PGSQL_PROCS \
    --style $EBS_MOUNT/vector-datasource/osm2pgsql.style \
    --flat-nodes $EBS_MOUNT/flatnodes \
    $EBS_MOUNT/planet-latest.osm.pbf

# Download and import supporting data
cd $SOURCE_DIR
SOURCE_VENV="${SOURCE_DIR}/venv"
virtualenv $SOURCE_VENV
source "${SOURCE_VENV}/bin/activate"
pip -q install -U jinja2 pyaml
cd data
python bootstrap.py
make -f Makefile-import-data
./import-shapefiles.sh | psql -d $PGDATABASE -U $PGUSER -h localhost
./perform-sql-updates.sh -d $PGDATABASE -U $PGUSER -h localhost
make -f Makefile-import-data clean
deactivate

# Downloading Who's on First neighbourhoods data
wget --quiet -P $EBS_MOUNT https://s3.amazonaws.com/mapzen-tiles-assets/wof/dev/wof_neighbourhoods.pgdump
pg_restore --clean -d $PGDATABASE -U $PGUSER -h localhost -O "${EBS_MOUNT}/wof_neighbourhoods.pgdump"

