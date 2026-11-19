`timescale 1ns/1ps
interface strict_bus_if(input logic clk);
  logic rst_n=0;
  logic [2:0] cv=0, cr, rd=0, rv, rr=0, err;
  logic [2:0][31:0] addr=0, wd=0, data;
  logic [2:0][3:0] mask=0;
  logic scv, scr, srd, srv, srr, serr;
  logic [31:0] sa, swd, sd, groups;
  logic [3:0] sm;
  logic [31:0] base, wptr, wp_data;
  logic valid, done, wp_ready, wp_read=0;
endinterface
