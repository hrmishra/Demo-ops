# Use an official Go runtime as the base image
FROM golang:1.17

# Set the working directory in the container
WORKDIR /go/src/app

# Copy the current directory contents into the container at /go/src/app
COPY . .

# Build the Go app
RUN go build -o main .

# Run main when the container starts
ENTRYPOINT ["./main"]