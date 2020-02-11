# dynamic
Import data from CSV into Scylla DB
You should be good to go on MacOS with docker, Xcode 11 and Swift 5 installed.

# Installation
Run Scylla DB in docker container:
```
docker run --name dy-scylla -p 9042:9042 -d scylladb/scylla
```
Open cqlsh:
```
docker exec -it dy-scylla cqlsh
```

Clone dynamic repo:
git clone https://github.com/fimkap/dynamic

Open the project in Xcode.
Build the project.
Open terminal app and cd into the project root directory.
Run the following command to create a csv file with 1M lines in the current dir:
```
./DerivedData/dynamic/Build/Products/Debug/dynamic 232.csv 1000000
```
Run the following command to load the data into Scylla container and index it:
```
time ./DerivedData/dynamic/Build/Products/Debug/dynamic 232.csv
```
It can take around 6 mins for 1M lines.
Check with cqlsh:
```
desc keyspaces;
use dynamic;
desc tables;
select count(*) from c232;
```
Beware that select count might time out on million rows.

