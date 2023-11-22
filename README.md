# echo

This is a simple Go server that echoes the request you send it. This was made to help me test other services that need to send webhooks and I am not sure what information they will send. For this reason, I will configure them to send to this service and I can inspect the request made. 

Currently, it is hosted on  https://shonei-portfolio.uc.r.appspot.com
Please note this is public so anyone can view any of the requests you sent. Please don't send in your credentials. 

Here is a small example of how to use it. You can send a request to any endpoint as long as you send it valid JSON it will respond with the parsed HTTP request you made 

```bash
curl -X POST -d '{\"value\":4}' https://shonei-portfolio.uc.r.appspot.com/test | jq .
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100   521  100   510  100    11   2400     51 --:--:-- --:--:-- --:--:--  2457
{
  "method": "POST",
  "url": "/test",
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Content-Length": [
      "11"
    ],
    "Content-Type": [
      "application/x-www-form-urlencoded"
    ],
    "User-Agent": [
      "curl/8.0.1"
    ],
    "Via": [
      "1.1 google"
    ],
    "X-Appengine-City": [
      "manchester"
    ],
    "X-Appengine-Citylatlong": [
      "53.480759,-2.242630"
    ],
    "X-Appengine-Country": [
      "GB"
    ],
    "X-Appengine-Region": [
      "eng"
    ],
    "X-Cloud-Trace-Context": [
      "6da1c4ad7670c194350f335c445033f0/6803777964456816794"
    ],
    "X-Forwarded-For": [
      "XXX.XX.XXX.XX
    ],
    "X-Forwarded-Proto": [
      "https"
    ]
  },
  "body": {
    "value": 4
  }
}
```
Later on, you can retrieve the last 5 requests made to an endpoint by adding `/logs` at the beginning of the path. The request are stored in memory right now so there is no guarantee they won't be lost when the service restarts. 

```bash
curl  https://shonei-portfolio.uc.r.appspot.com/logs/test | jq .                     
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  1020  100  1020    0     0   6487      0 --:--:-- --:--:-- --:--:--  6538
{
  "method": "POST",
  "url": "/test",
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Content-Length": [
      "11"
    ],
    "Content-Type": [
      "application/x-www-form-urlencoded"
    ],
    "User-Agent": [
      "curl/8.0.1"
    ],
    "Via": [
      "1.1 google"
    ],
    "X-Appengine-City": [
      "manchester"
    ],
    "X-Appengine-Citylatlong": [
      "53.480759,-2.242630"
    ],
    "X-Appengine-Country": [
      "GB"
    ],
    "X-Appengine-Region": [
      "eng"
    ],
    "X-Cloud-Trace-Context": [
      "6da1c4ad7670c194350f335c445033f0/6803777964456816794"
    ],
    "X-Forwarded-For": [
      "XXX.XX.XXX.XX
    ],
    "X-Forwarded-Proto": [
      "https"
    ]
  },
  "body": {
    "value": 4
  }
}
{
  "method": "POST",
  "url": "/test",
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Content-Length": [
      "11"
    ],
    "Content-Type": [
      "application/x-www-form-urlencoded"
    ],
    "User-Agent": [
      "curl/8.0.1"
    ],
    "Via": [
      "1.1 google"
    ],
    "X-Appengine-City": [
      "manchester"
    ],
    "X-Appengine-Citylatlong": [
      "53.480759,-2.242630"
    ],
    "X-Appengine-Country": [
      "GB"
    ],
    "X-Appengine-Region": [
      "eng"
    ],
    "X-Cloud-Trace-Context": [
      "8df8867ec47f3fa3a3e8de1036323574/6956888757812203839"
    ],
    "X-Forwarded-For": [
      "XXX.XX.XXX.XX
    ],
    "X-Forwarded-Proto": [
      "https"
    ]
  },
  "body": {
    "value": 4
  }
}
```
