# dynamic
Import data from CSV into Scylla DB
You need Docker and Swift 6.1 or later, on macOS or Linux.

# Installation
Run Scylla DB in docker container:
```
docker run --name dy-scylla -p 9042:9042 -d scylladb/scylla
```
Or alternatively you can mount a volume to container. The Scylla docs say that is better suited for real load.
On Mac /private/var/ or /var is not allowed for mount to Docker by default. You can use another location.
```
sudo mkdir -p /var/lib/scylla/data /var/lib/scylla/commitlog /var/lib/scylla/hints /var/lib/scylla/view_hints
docker run --name dy-scylla -p 9042:9042 --volume /private/var/lib/scylla:/var/lib/scylla -d scylladb/scylla
```
Wait a bit until Scylla is ready. Open cqlsh:
```
docker exec -it dy-scylla cqlsh
```
If it gives error, wait a bit more and try again.

Clone dynamic repo:
```
git clone https://github.com/fimkap/dynamic
```

Build it:
```
cd dynamic
swift build -c release
```

# Assumptions
Format of csv file:
```
product_id, product_name, product_image_url,  product_price, product_categories, product_stock
123, iPhone11, http://apple.com/iphone11, 650.00, cellular, 500
987, iPadMini, http://apple.com/ipadMini, 450.00,  tablet, 250
```
The file should be in the current directory.

# Use
Open terminal app and cd into the project root directory.
Run the following command to create a csv file with 1M lines in the current dir:
```
.build/release/dynamic 232.csv 1000000
```
Run the following command to load the data into Scylla container and index it:
```
time .build/release/dynamic 232.csv
```
It can take around 6 mins for 1M lines.
Ignore the driver's message "Schema change is not yet implemented".
Check with cqlsh:
```
desc keyspaces;
use dynamic;
desc tables;
select count(*) from c232;
```
Beware that select count might time out on million rows.
