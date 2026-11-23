/*
  Treasury panel — SKELETON, for Jon to fill in.

  This mirrors the MEISTER's MeisterPanel.tsx. useBackend gives you
  the data the DM side sent (ui_data / ui_static_data) and act() to
  send a button press back. The action strings here must match the
  switch in ui_act in treasury_tgui.dm. The Data type must list every
  field the DM side sends, by the same names.
*/
import { Box, Button, Section, Stack } from 'tgui-core/components';

import { useBackend } from '../backend';
import { Window } from '../layouts';

type Data = {
  treasury_id: string;
  total: number;
  counter: number;
  locked: boolean;
  owner_minimum: number;
  viewer_balance: number;
  is_owner: boolean;
  is_holder: boolean;
};

export const TreasuryPanel = () => {
  const { data, act } = useBackend<Data>();

  return (
    <Window title="Treasury" width={420} height={380} theme="parchment">
      <Window.Content>
        <Section title="Vault">
          <Stack vertical>
            <Stack.Item>
              <Box>Total vaulted: {data.total}m</Box>
            </Stack.Item>
            <Stack.Item>
              <Box>Counter (unassigned): {data.counter}m</Box>
            </Stack.Item>
            <Stack.Item>
              <Box>Your balance: {data.viewer_balance}m</Box>
            </Stack.Item>
            <Stack.Item>
              <Box>{data.locked ? 'Locked' : 'Unlocked'}</Box>
            </Stack.Item>
            <Stack.Item>
              <Box>Minimum to open a balance: {data.owner_minimum}m</Box>
            </Stack.Item>
          </Stack>
        </Section>
        <Section title="Actions">
          <Stack>
            <Stack.Item>
              <Button onClick={() => act('deposit')}>
                Deposit counter
              </Button>
            </Stack.Item>
            <Stack.Item>
              <Button onClick={() => act('withdraw')}>
                Withdraw
              </Button>
            </Stack.Item>
            <Stack.Item>
              <Button onClick={() => act('set_primary')}>
                Set primary
              </Button>
            </Stack.Item>
          </Stack>
        </Section>
      </Window.Content>
    </Window>
  );
};
