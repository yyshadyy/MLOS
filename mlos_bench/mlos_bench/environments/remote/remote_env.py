#
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
"""
Remotely executed benchmark/script environment.
"""

import logging
from typing import Iterable, Optional, Tuple

from mlos_bench.environments.status import Status
from mlos_bench.environments.base_environment import Environment
from mlos_bench.services.base_service import Service
from mlos_bench.services.types.remote_exec_type import SupportsRemoteExec
from mlos_bench.services.types.vm_provisioner_type import SupportsVMOps
from mlos_bench.tunables.tunable_groups import TunableGroups

_LOG = logging.getLogger(__name__)


class RemoteEnv(Environment):
    """
    Environment to run benchmarks and scripts on a remote host.
    """

    def __init__(self,
                 *,
                 name: str,
                 config: dict,
                 global_config: Optional[dict] = None,
                 tunables: Optional[TunableGroups] = None,
                 service: Optional[Service] = None):
        """
        Create a new environment for remote execution.

        Parameters
        ----------
        name: str
            Human-readable name of the environment.
        config : dict
            Free-format dictionary that contains the benchmark environment
            configuration. Each config must have at least the "tunable_params"
            and the "const_args" sections.
            `RemoteEnv` must also have at least some of the following parameters:
            {setup, run, teardown, wait_boot}
        global_config : dict
            Free-format dictionary of global parameters (e.g., security credentials)
            to be mixed in into the "const_args" section of the local config.
        tunables : TunableGroups
            A collection of tunable parameters for *all* environments.
        service: Service
            An optional service object (e.g., providing methods to
            deploy or reboot a VM, etc.).
        """
        super().__init__(name=name, config=config, global_config=global_config, tunables=tunables, service=service)

        assert self._service is not None and isinstance(self._service, SupportsRemoteExec), \
            "RemoteEnv requires a service that supports remote execution operations"
        self._remote_exec_service: SupportsRemoteExec = self._service

        # TODO: Refactor this as "host" and "os" operations to accommodate SSH service.
        assert self._service is not None and isinstance(self._service, SupportsVMOps), \
            "RemoteEnv requires a service that supports host operations"
        self._host_service: SupportsVMOps = self._service

        self._wait_boot = self.config.get("wait_boot", False)
        self._script_setup = self.config.get("setup")
        self._script_run = self.config.get("run")
        self._script_teardown = self.config.get("teardown")

        if self._script_setup is None and \
           self._script_run is None and \
           self._script_teardown is None and \
           not self._wait_boot:
            raise ValueError("At least one of {setup, run, teardown}" +
                             " must be present or wait_boot set to True.")

    def setup(self, tunables: TunableGroups, global_config: Optional[dict] = None) -> bool:
        """
        Check if the environment is ready and set up the application
        and benchmarks on a remote host.

        Parameters
        ----------
        tunables : TunableGroups
            A collection of tunable OS and application parameters along with their
            values. Setting these parameters should not require an OS reboot.
        global_config : dict
            Free-format dictionary of global parameters of the environment
            that are not used in the optimization process.

        Returns
        -------
        is_success : bool
            True if operation is successful, false otherwise.
        """
        if not super().setup(tunables, global_config):
            return False

        if self._wait_boot:
            _LOG.info("Wait for the remote environment to start: %s", self)
            (status, params) = self._host_service.vm_start(self._params)
            if status.is_pending:
                (status, _) = self._host_service.wait_vm_operation(params)
            if not status.is_succeeded:
                return False

        if self._script_setup:
            _LOG.info("Set up the remote environment: %s", self)
            (status, _) = self._remote_exec(self._script_setup)
            _LOG.info("Remote set up complete: %s :: %s", self, status)
            self._is_ready = status.is_succeeded
        else:
            self._is_ready = True

        return self._is_ready

    def run(self) -> Tuple[Status, Optional[dict]]:
        """
        Runs the run script on the remote environment.

        This can be used to, for instance, submit a new experiment to the
        remote application environment by (re)configuring an application and
        launching the benchmark, or run a script that collects the results.

        Returns
        -------
        (status, output) : (Status, dict)
            A pair of (Status, output) values, where `output` is a dict
            with the results or None if the status is not COMPLETED.
            If run script is a benchmark, then the score is usually expected to
            be in the `score` field.
        """
        _LOG.info("Run script remotely on: %s", self)
        (status, _) = result = super().run()
        if not (status.is_ready and self._script_run):
            return result

        result = self._remote_exec(self._script_run)
        _LOG.info("Remote run complete: %s :: %s", self, result)
        return result

    def teardown(self) -> None:
        """
        Clean up and shut down the remote environment.
        """
        if self._script_teardown:
            _LOG.info("Remote teardown: %s", self)
            (status, _) = self._remote_exec(self._script_teardown)
            _LOG.info("Remote teardown complete: %s :: %s", self, status)
        super().teardown()

    def _remote_exec(self, script: Iterable[str]) -> Tuple[Status, Optional[dict]]:
        """
        Run a script on the remote host.

        Parameters
        ----------
        script : [str]
            List of commands to be executed on the remote host.

        Returns
        -------
        result : (Status, dict)
            A pair of Status and dict with the benchmark/script results.
            Status is one of {PENDING, SUCCEEDED, FAILED, TIMED_OUT}
        """
        _LOG.debug("Submit script: %s", self)
        (status, output) = self._remote_exec_service.remote_exec(script, self._params)
        _LOG.debug("Script submitted: %s %s :: %s", self, status, output)
        if status in {Status.PENDING, Status.SUCCEEDED}:
            (status, output) = self._remote_exec_service.get_remote_exec_results(output)
            # TODO: extract the results from `output`.
        _LOG.debug("Status: %s :: %s", status, output)
        return (status, output)
