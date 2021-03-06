// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class core_ibex_base_test extends uvm_test;

  core_ibex_env                                   env;
  core_ibex_env_cfg                               cfg;
  virtual clk_if                                  clk_vif;
  virtual core_ibex_dut_probe_if                  dut_vif;
  virtual ibex_mem_intf                           dmem_vif;
  mem_model_pkg::mem_model                        mem;
  core_ibex_vseq                                  vseq;
  bit                                             enable_irq_seq;
  bit                                             enable_debug_seq;
  irq_seq                                         irq_seq_h;
  int unsigned                                    timeout_in_cycles = 2000000;
  // If no signature_addr handshake functionality is desired between the
  // testbench and the generated code, the test will wait for the specified
  // number of cycles before starting stimulus sequences (irq and debug)
  int unsigned                                    stimulus_delay = 800;
  uvm_tlm_analysis_fifo #(ibex_mem_intf_seq_item) addr_ph_port;

  `uvm_component_utils(core_ibex_base_test)

  function new(string name="", uvm_component parent=null);
    core_ibex_report_server ibex_report_server;
    super.new(name, parent);
    ibex_report_server = new();
    uvm_report_server::set_server(ibex_report_server);
    addr_ph_port = new("addr_ph_port_test", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    $value$plusargs("timeout_in_cycles=%0d", timeout_in_cycles);
    if (!uvm_config_db#(virtual clk_if)::get(null, "", "clk_if", clk_vif)) begin
      `uvm_fatal(get_full_name(), "Cannot get clk_if")
    end
    if (!uvm_config_db#(virtual core_ibex_dut_probe_if)::get(null, "", "dut_if", dut_vif)) begin
      `uvm_fatal(get_full_name(), "Cannot get dut_if")
    end
    if (!uvm_config_db#(virtual ibex_mem_intf)::get(null, "*data_if_slave*", "vif", dmem_vif)) begin
      `uvm_fatal(get_full_name(), "Cannot get dmem_vif")
    end
    env = core_ibex_env::type_id::create("env", this);
    cfg = core_ibex_env_cfg::type_id::create("cfg", this);
    uvm_config_db#(core_ibex_env_cfg)::set(this, "*", "cfg", cfg);
    mem = mem_model_pkg::mem_model#()::type_id::create("mem");
    // Create virtual sequence and assign memory handle
    vseq = core_ibex_vseq::type_id::create("vseq");
    vseq.mem = mem;
    vseq.cfg = cfg;
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    env.data_if_slave_agent.monitor.addr_ph_port.connect(this.addr_ph_port.analysis_export);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    dut_vif.fetch_enable = 1'b0;
    clk_vif.wait_clks(100);
    load_binary_to_mem();
    dut_vif.fetch_enable = 1'b1;
    vseq.start(env.vseqr);
    wait_for_test_done();
    phase.drop_objection(this);
  endtask

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
  endfunction

  function void load_binary_to_mem();
    string      bin;
    bit [7:0]   r8;
    bit [31:0]  addr = `BOOT_ADDR;
    int         f_bin;
    void'($value$plusargs("bin=%0s", bin));
    if (bin == "")
      `uvm_fatal(get_full_name(), "Please specify test binary by +bin=binary_name")
    `uvm_info(get_full_name(), $sformatf("Running test : %0s", bin), UVM_LOW)
    f_bin = $fopen(bin,"rb");
    if (!f_bin)
      `uvm_fatal(get_full_name(), $sformatf("Cannot open file %0s", bin))
    while ($fread(r8,f_bin)) begin
      `uvm_info(`gfn, $sformatf("Init mem [0x%h] = 0x%0h", addr, r8), UVM_FULL)
      mem.write(addr, r8);
      addr++;
    end
  endfunction

  virtual task wait_for_test_done();
    // TODO(taliu): We need a consistent approach to determine the test is completed for both
    // random instruction test and firmware based test. For example, it could be done by writing to
    // a specific memory location of the test signature. Right now the random instruction generator
    // use ecall instruction to indicate the end of the program. It could be changed to align with
    // firmware test completion mechanism.
    fork
      begin
        wait (dut_vif.ecall === 1'b1);
        vseq.stop();
        `uvm_info(`gfn, "ECALL instruction is detected, test done", UVM_LOW)
        // De-assert fetch enable to finish the test
        dut_vif.fetch_enable = 1'b0;
        // Wait some time for the remaining instruction to finish
        clk_vif.wait_clks(100);
      end
      begin
        clk_vif.wait_clks(timeout_in_cycles);
        `uvm_fatal(`gfn, "TEST TIMEOUT!!")
      end
    join_any
  endtask

  virtual task wait_for_mem_txn(input bit[ibex_mem_intf_agent_pkg::ADDR_WIDTH-1:0] ref_addr,
                                input bit[ibex_mem_intf_agent_pkg::DATA_WIDTH-1:0] ref_val,
                                output bit[ibex_mem_intf_agent_pkg::DATA_WIDTH-1:0] data);
    ibex_mem_intf_seq_item mem_txn;
    forever begin
      addr_ph_port.get(mem_txn);
      if (mem_txn.addr == ref_addr && mem_txn.data == ref_val && mem_txn.read_write == WRITE) begin
        data = mem_txn.data;
        return;
      end
    end
  endtask

endclass
