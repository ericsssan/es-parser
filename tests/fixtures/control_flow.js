if (x > 0) {
    console.log("positive");
} else if (x < 0) {
    console.log("negative");
} else {
    console.log("zero");
}

while (i < 10) {
    i++;
}

do {
    i--;
} while (i > 0);

for (let i = 0; i < 10; i++) {
    if (i === 5) break;
    if (i === 3) continue;
}

for (const key in obj) {
    console.log(key);
}

for (const item of arr) {
    console.log(item);
}

switch (action) {
    case "start":
        start();
        break;
    case "stop":
        stop();
        break;
    default:
        idle();
}
