#!/bin/sh

metadata=`curl http://169.254.169.254/latest/meta-data/ 2>/dev/null`

echo "{"
for line in ${metadata}; do
    val=`curl http://169.254.169.254/latest/meta-data/$line 2>/dev/null | tr "\n" ","`
    # echo "\"$line\": \"${val}\","
done
# echo "\"dummy\": \"foo\""
echo "}"
