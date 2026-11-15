package com.example.model;

public class Customer extends Person {
    private int secret;
    int packagePrivate;

    public String getEmail() { return "e"; }
    public static Customer guest() { return new Customer(); }
}
